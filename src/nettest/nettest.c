/* Minimal network check for a bottle: DNS + TCP + TLS via WinHTTP. */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <ws2tcpip.h>
int main(void) {
    WSADATA w; WSAStartup(MAKEWORD(2,2), &w);
    struct addrinfo *res = NULL, hints = {0}; hints.ai_family = AF_INET;
    int r = getaddrinfo("api.steampowered.com", "443", &hints, &res);
    printf("DNS api.steampowered.com: %s\n", r == 0 ? "ok" : "FAILED");
    if (r == 0) { char ip[64]; getnameinfo(res->ai_addr, (socklen_t)res->ai_addrlen, ip, sizeof ip, NULL, 0, NI_NUMERICHOST); printf("  -> %s\n", ip); freeaddrinfo(res); }
    HINTERNET s = WinHttpOpen(L"nettest/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET c = s ? WinHttpConnect(s, L"api.steampowered.com", INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    HINTERNET q = c ? WinHttpOpenRequest(c, L"GET", L"/ISteamWebAPIUtil/GetServerInfo/v1/", NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) : NULL;
    BOOL ok = q && WinHttpSendRequest(q, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(q, NULL);
    DWORD status = 0, len = sizeof status;
    if (ok) WinHttpQueryHeaders(q, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &len, NULL);
    printf("HTTPS GET api.steampowered.com: %s (status %lu, GetLastError %lu)\n", ok ? "ok" : "FAILED", status, GetLastError());
    if (ok) { char buf[256]; DWORD n = 0; WinHttpReadData(q, buf, sizeof buf - 1, &n); buf[n] = 0; printf("  body: %.120s\n", buf); }
    return ok ? 0 : 1;
}
