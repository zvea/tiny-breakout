// Interactive RTL simulation: Verilator model + tiny HTTP server. Open http://localhost:PORT/
//
// GET /stream   long-lived response; the server runs the game at 60 fps (real hardware rate)
//               and pushes every frame as [u32 little-endian length][RLE payload]. RLE payload
//               is (count, RRGGBB) byte pairs covering 640x480. Only one viewer at a time: a new
//               /stream takes over from the previous one.
// GET /keys?k=K sets the controls. K bits: 1 left, 2 right, 4 fire (B), 8 autoplay, 16 reset.
// Anything else returns index.html.
//
// Streaming (rather than request/response per frame) keeps the frame rate independent of the
// network round-trip time, e.g. through an SSH port forward.
#include "sim.h"
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
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
static void reply(int fd, const char *type, const std::string &body) {
  char hdr[256];
  int h = snprintf(hdr, sizeof hdr,
                   "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                   "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
                   type, body.size());
  send_all(fd, hdr, h);
  send_all(fd, body.data(), body.size());
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
  using clk = std::chrono::steady_clock;
  const auto period = std::chrono::nanoseconds(1000000000 / 60);
  auto next = clk::now();
  auto t_stat = clk::now();
  int frames = 0;
  std::string msg;
  int fd = -1;  // current viewer; owned (and closed) only by this thread
  for (;;) {
    {
      std::unique_lock<std::mutex> lk(mu);
      if (fd < 0 && pending_fd < 0) {
        cv.wait(lk, [] { return pending_fd >= 0; });
        next = clk::now();
      }
      if (pending_fd >= 0) {  // newest viewer wins
        if (fd >= 0) close(fd);
        fd = pending_fd;
        pending_fd = -1;
      }
    }
    if (reset_req.exchange(false)) g.reset();
    int k = keys.load();
    g.pad_bits = ((k & 1) << 5) | ((k & 2) << 3) | ((k & 4) << 1);  // left, right, A (fire)
    g.autoplay = k & 8;
    g.frame();

    msg.assign(4, '\0');
    const auto &fb = g.fb;
    for (size_t i = 0; i < fb.size();) {
      size_t j = i;
      uint8_t v = lut[fb[i]];
      while (j < fb.size() && j - i < 255 && lut[fb[j]] == v) j++;
      msg += (char)(j - i);
      msg += (char)v;
      i = j;
    }
    uint32_t len = msg.size() - 4;
    memcpy(&msg[0], &len, 4);
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
  int port = argc > 1 ? atoi(argv[1]) : 8765;
  std::string html_path = argc > 2 ? argv[2] : "index.html";
  signal(SIGPIPE, SIG_IGN);  // a client disconnecting mid-write must not kill the server

  int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (sockaddr *)&a, sizeof a) || listen(s, 16)) {
    perror("bind");
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
      reply(c, "text/plain", "ok");
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
      std::lock_guard<std::mutex> lk(mu);
      if (pending_fd >= 0) close(pending_fd);  // never handed over: safe to close here
      pending_fd = c;
      cv.notify_one();
    } else {
      std::ifstream f(html_path);
      std::stringstream ss;
      ss << f.rdbuf();
      timeval tv1{0, 500000};
      setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv1, sizeof tv1);
      reply(c, "text/html", ss.str());
      close(c);
    }
  }
}
