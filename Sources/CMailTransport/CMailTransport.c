#include "CMailTransport.h"
#include <curl/curl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <pthread.h>
#include <poll.h>
#include <time.h>
struct OrbitaIMAPConnection { CURL *curl; atomic_int cancelled; double deadline; };
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static double now(void) { struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value); return value.tv_sec + value.tv_nsec / 1e9; }
static int progress(void *context, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    return atomic_load(&((OrbitaIMAPConnection *)context)->cancelled);
}
OrbitaIMAPConnection *orbita_imap_create(void) {
    pthread_once(&once, initialize);
    OrbitaIMAPConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) return NULL;
    atomic_init(&connection->cancelled, 0);
    connection->curl = curl_easy_init();
    if (!connection->curl) { free(connection); return NULL; }
    return connection;
}
int orbita_imap_connect(OrbitaIMAPConnection *connection, const char *url, const char *user, const char *password) {
    CURL *curl = connection->curl;
    connection->deadline = now() + 45;
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERNAME, user);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, password);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "imap,imaps");
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_NOPROXY, "*");
    curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 45L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, progress);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, connection);
    return (int)curl_easy_perform(curl);
}
static int wait_socket(OrbitaIMAPConnection *connection, short events) {
    if (atomic_load(&connection->cancelled)) return CURLE_ABORTED_BY_CALLBACK;
    if (now() >= connection->deadline) return CURLE_OPERATION_TIMEDOUT;
    curl_socket_t socket;
    CURLcode code = curl_easy_getinfo(connection->curl, CURLINFO_ACTIVESOCKET, &socket);
    if (code || socket == CURL_SOCKET_BAD) return CURLE_COULDNT_CONNECT;
    struct pollfd descriptor = { socket, events, 0 };
    int status = poll(&descriptor, 1, 100);
    if (status < 0) return CURLE_RECV_ERROR;
    return CURLE_OK;
}
int orbita_imap_send(OrbitaIMAPConnection *connection, const unsigned char *bytes, size_t count, size_t *sent) {
    int code = wait_socket(connection, POLLOUT);
    if (code) return code;
    return curl_easy_send(connection->curl, bytes, count, sent);
}
int orbita_imap_receive(OrbitaIMAPConnection *connection, unsigned char *bytes, size_t count, size_t *received) {
    if (atomic_load(&connection->cancelled)) return CURLE_ABORTED_BY_CALLBACK;
    if (now() >= connection->deadline) return CURLE_OPERATION_TIMEDOUT;
    CURLcode code = curl_easy_recv(connection->curl, bytes, count, received);
    if (code == CURLE_AGAIN) { int status = wait_socket(connection, POLLIN); if (status) return status; }
    return code;
}
void orbita_imap_cancel(OrbitaIMAPConnection *connection) { atomic_store(&connection->cancelled, 1); }
void orbita_imap_close(OrbitaIMAPConnection *connection) { if (connection) { curl_easy_cleanup(connection->curl); free(connection); } }
#ifdef ORBITA_WIRE_TEST
void orbita_imap_fixture_ca(OrbitaIMAPConnection *connection, const char *path) { curl_easy_setopt(connection->curl, CURLOPT_CAINFO, path); }
#endif
