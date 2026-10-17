/* Resolve with AF_UNSPEC (what Steam does) and try a TCP connect to each address. */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
int main(int argc, char **argv) {
    const char *host = argc > 1 ? argv[1] : "api.steampowered.com";
    WSADATA w; WSAStartup(MAKEWORD(2,2), &w);
    struct addrinfo *res = NULL, *p, hints = {0}; hints.ai_socktype = SOCK_STREAM;
    int r = getaddrinfo(host, "443", &hints, &res);
    if (r) { printf("getaddrinfo(%s) failed: %d\n", host, r); return 1; }
    for (p = res; p; p = p->ai_next) {
        char ip[64]; getnameinfo(p->ai_addr, (socklen_t)p->ai_addrlen, ip, sizeof ip, NULL, 0, NI_NUMERICHOST);
        SOCKET s = socket(p->ai_family, SOCK_STREAM, 0);
        DWORD t = 4000; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&t, sizeof t); setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (char*)&t, sizeof t);
        int c = connect(s, p->ai_addr, (int)p->ai_addrlen);
        printf("%s %-40s connect: %s (err %d)\n", p->ai_family == AF_INET6 ? "v6" : "v4", ip, c == 0 ? "ok" : "FAILED", c == 0 ? 0 : WSAGetLastError());
        closesocket(s);
    }
    freeaddrinfo(res); return 0;
}
