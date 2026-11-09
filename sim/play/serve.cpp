// SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Interactive RTL simulation: Verilator model + tiny HTTP server. Open http://localhost:PORT/
//
// GET /stream   long-lived response; the server runs the game at up to 60 fps (the real
//               hardware rate; on a slower CPU it simulates every frame anyway, in slow
//               motion) and pushes every frame as [u32 video length][u32 audio sample count]
//               [video][audio], little-endian. Video is (count, RRGGBB) byte pairs covering
//               640x480. Audio is the Audio Pmod's output (uio[7], see sim.h) as s16 at
//               48 kHz, stretched to the time the frame really took, at its true pitch (see
//               stretch.h), so it plays continuously down to 3.75 fps (a stretch of 16). Only
//               one viewer at a time: a new /stream takes over from the previous one, which
//               gets a last header with video length 0xFFFFFFFF (and no samples) before its
//               stream ends, so it knows not to reconnect.
// GET /keys?k=K sets the controls. K bits: 1 left, 2 right, 4 fire (gamepad A), 8 autoplay,
//               16 reset.
// Anything else returns the page: the path given as the second argument, by default
//               index.html in the directory above the executable's (sim/play, above
//               obj_serve), so the server runs from anywhere. It is read for each request.
//
// Streaming (rather than request/response per frame) keeps the frame rate independent of the
// network round-trip time, e.g. through an SSH port forward.
#include "sim.h"
#include "stretch.h"
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/time.h>
#include <thread>
#include <unistd.h>

static bool send_all(int fd, const void *p, size_t n) {
  const char *c = (const char *)p;
  while (n) {
    ssize_t w = write(fd, c, n);
    if (w <= 0) return false;
    c += w;
    n -= w;
  }
  return true;
}
// The whole file, or false if it can't be read (or is empty).
static bool read_file(const std::string &path, std::string &out) {
  std::ifstream f(path, std::ios::binary);
  std::stringstream ss;
  if (f) ss << f.rdbuf();
  out = ss.str();
  return !out.empty();
}
static void reply(int fd, const char *status, const char *type, const std::string &body) {
  char hdr[256];
  int h = snprintf(hdr, sizeof hdr,
                   "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                   "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
                   status, type, body.size());
  send_all(fd, hdr, h);
  send_all(fd, body.data(), body.size());
}

// Ends a viewer's stream with the takeover header (video length 0xFFFFFFFF, no samples), so
// it knows another viewer has the stream and doesn't reconnect. Its buffer may be full (a
// stalled tab): wait a little for room, but not long.
static void end_taken_over(int fd) {
  const uint32_t taken_over[2] = {0xFFFFFFFFu, 0};
  timeval tv{0, 200000};
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  send_all(fd, taken_over, sizeof taken_over);
  close(fd);
}

static std::atomic<int> keys{0};
static std::atomic<bool> reset_req{false};
static std::mutex mu;
static std::condition_variable cv;
static int pending_fd = -1;  // new viewer handed over by the accept loop (guarded by mu)

// Runs the game at 60 fps while a viewer is connected, pushing frames to it.
static void streamer() {
  uint8_t lut[256];  // TinyVGA PMOD byte {hs,B0,G0,R0,vs,B1,G1,R1} -> RRGGBB
  for (int o = 0; o < 256; o++) {
    int r = ((o >> 0) & 1) << 1 | ((o >> 4) & 1);
    int g = ((o >> 1) & 1) << 1 | ((o >> 5) & 1);
    int b = ((o >> 2) & 1) << 1 | ((o >> 6) & 1);
    lut[o] = (r << 4) | (g << 2) | b;
  }
  Game g;
  g.reset();
  g.capture_audio = true;
  // Audio: each frame's 800 samples are stretched so the output keeps pace with real time.
  // The output owed is 48 kHz x the time since audio started, less what has been sent. The
  // stretch ratio starts from the frame time over 1/60 s, smoothed, between 1 (full speed)
  // and 16 (3.75 fps; below that the output falls behind). That alone runs a few percent
  // high at full speed, where a late frame is followed by an early one that the clamp at 1
  // ignores, and the input it leaves over would wait in the stretcher as an ever-growing
  // delay; on a slow machine it can run low, and the output falls behind. So it is corrected
  // both ways, in proportion: it is divided by 1 + the input waiting beyond what this frame's
  // grains need, in units of 0.5 s, and multiplied by 1 + the output still owed from earlier
  // frames, in the same units (so 0.5 s of either halves or doubles it). That holds the delay
  // to a few tens of ms, and the output to real time.
  Stretcher stretcher;
  long sent = 0;
  double ratio = 1;
  using clk = std::chrono::steady_clock;
  auto audio_start = clk::now(), last_frame = clk::now();
  const auto period = std::chrono::nanoseconds(1000000000 / 60);
  auto next = clk::now();
  auto t_stat = clk::now();
  int frames = 0;
  std::string msg;
  int fd = -1;  // current viewer; owned (and closed) only by this thread
  for (;;) {
    int old_fd = -1;  // a viewer taken over, told so once the lock is released
    bool fresh = false;
    {
      std::unique_lock<std::mutex> lk(mu);
      if (fd < 0 && pending_fd < 0) {
        cv.wait(lk, [] { return pending_fd >= 0; });
        next = clk::now();
      }
      if (pending_fd >= 0) {  // newest viewer wins: its audio starts afresh
        old_fd = fd;
        fd = pending_fd;
        pending_fd = -1;
        fresh = true;
      }
    }
    if (old_fd >= 0) end_taken_over(old_fd);
    if (fresh) {
      stretcher.reset();
      sent = 0;
      ratio = 1;
      audio_start = last_frame = clk::now();
    }
    if (reset_req.exchange(false)) g.reset();
    int k = keys.load();
    g.pad_bits = ((k & 1) << 5) | ((k & 2) << 3) | ((k & 4) << 1);  // left, right, A (fire)
    g.autoplay = k & 8;
    g.frame();

    auto t = clk::now();
    double dt = std::chrono::duration<double>(t - last_frame).count();
    last_frame = t;
    ratio += 0.1 * (std::min(16.0, std::max(1.0, dt * 60)) - ratio);
    long owed = std::lround(48000 * std::chrono::duration<double>(t - audio_start).count()) - sent;
    if (owed > 24000) {  // half a second behind (a stall): don't try to catch up
      // In seconds, as a double: sent * 1e9 ns would overflow a long after 53 h of streaming
      audio_start = t - std::chrono::duration_cast<clk::duration>(
                            std::chrono::duration<double>(sent / 48000.0));
      owed = 0;
    }
    stretcher.push(g.audio.data(), Game::AUDIO_PER_FRAME);
    double excess = stretcher.backlog() - (Stretcher::AHEAD + Game::AUDIO_PER_FRAME);
    double carry = std::max(0.0, owed - 48000 * dt);
    double r = std::min(16.0, std::max(0.5, ratio * (1 + carry / 24000) / (1 + excess / 24000)));
    std::vector<float> audio = stretcher.pull(r, (int)std::max(0L, owed));
    sent += audio.size();

    msg.assign(8, '\0');
    const auto &fb = g.fb;
    for (size_t i = 0; i < fb.size();) {
      size_t j = i;
      uint8_t v = lut[fb[i]];
      while (j < fb.size() && j - i < 255 && lut[fb[j]] == v) j++;
      msg += (char)(j - i);
      msg += (char)v;
      i = j;
    }
    uint32_t len = msg.size() - 8, nsamp = audio.size();
    memcpy(&msg[0], &len, 4);
    memcpy(&msg[4], &nsamp, 4);
    for (float x : audio) {
      int v = (int)lrintf(x * 32767.0f);
      int16_t q = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
      msg.append((const char *)&q, 2);
    }
    if (!send_all(fd, msg.data(), msg.size())) {  // viewer went away
      close(fd);
      fd = -1;
      continue;
    }

    frames++;
    auto now = clk::now();
    if (now - t_stat >= std::chrono::seconds(5)) {
      printf("streaming %.1f fps\n", frames / std::chrono::duration<double>(now - t_stat).count());
      fflush(stdout);
      frames = 0;
      t_stat = now;
    }
    next += period;
    if (next < now - period) next = now;  // fell behind (slow CPU): don't try to catch up
    std::this_thread::sleep_until(next);
  }
}

int main(int argc, char **argv) {
  int port = 8765;
  char *end = nullptr;
  long p = argc > 1 ? strtol(argv[1], &end, 10) : port;
  if (argc > 3 || (argc > 1 && (end == argv[1] || *end || p < 1 || p > 65535))) {
    fprintf(stderr, "usage: %s [port (default 8765)] [index.html]\n", argv[0]);
    return 1;
  }
  port = (int)p;
  std::string html_path = "index.html", page;
  if (argc > 2) {
    html_path = argv[2];
  } else if (const char *slash = strrchr(argv[0], '/')) {  // obj_serve/.. holds the page
    html_path = std::string(argv[0], slash - argv[0]) + "/../index.html";
  }
  if (!read_file(html_path, page)) {
    fprintf(stderr, "Can't read the page %s: give its path as the second argument\n",
            html_path.c_str());
    return 1;
  }
  signal(SIGPIPE, SIG_IGN);  // a client disconnecting mid-write must not kill the server

  int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  if (s < 0) {
    perror("socket");
    return 1;
  }
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (sockaddr *)&a, sizeof a)) {
    fprintf(stderr, "Can't use port %d: %s\n", port, strerror(errno));
    return 1;
  }
  if (listen(s, 16)) {
    perror("listen");
    return 1;
  }
  printf("Tiny Breakout RTL sim: http://localhost:%d/\n", port);
  fflush(stdout);
  std::thread(streamer).detach();

  for (;;) {
    int c = accept(s, nullptr, nullptr);
    if (c < 0) continue;
    // Browsers / port forwarders open idle speculative connections: never block on them.
    timeval tv{0, 200000};
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char buf[4096];
    size_t n = 0;
    while (n < sizeof buf - 1) {  // read until end of request headers (or timeout)
      ssize_t r = read(c, buf + n, sizeof buf - 1 - n);
      if (r <= 0) break;
      n += r;
      buf[n] = 0;
      if (strstr(buf, "\r\n\r\n")) break;
    }
    buf[n] = 0;
    if (n == 0 || strncmp(buf, "GET ", 4)) {
      close(c);
      continue;
    }
    if (!strncmp(buf, "GET /keys?k=", 12)) {
      int k = atoi(buf + 12);
      if (k & 16) reset_req = true;
      keys = k & 15;
      reply(c, "200 OK", "text/plain", "ok");
      close(c);
    } else if (!strncmp(buf, "GET /stream", 11)) {
      const char *hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                        "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
      timeval tv0{2, 0};  // a stalled viewer is dropped after 2 s
      setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv0, sizeof tv0);
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      if (!send_all(c, hdr, strlen(hdr))) {
        close(c);
        continue;
      }
      int stale;
      {
        std::lock_guard<std::mutex> lk(mu);
        stale = pending_fd;  // never handed over: this thread may end it
        pending_fd = c;
        cv.notify_one();
      }
      if (stale >= 0) end_taken_over(stale);
    } else {
      timeval tv1{0, 500000};
      setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv1, sizeof tv1);
      if (read_file(html_path, page)) {
        reply(c, "200 OK", "text/html", page);
      } else {
        fprintf(stderr, "Can't read the page %s\n", html_path.c_str());
        reply(c, "500 Internal Server Error", "text/plain", "Can't read " + html_path + "\n");
      }
      close(c);
    }
  }
}
