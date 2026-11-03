#ifndef ORBITA_MAIL_TRANSPORT_H
#define ORBITA_MAIL_TRANSPORT_H
#include <stddef.h>
typedef struct OrbitaIMAPConnection OrbitaIMAPConnection;
OrbitaIMAPConnection *orbita_imap_create(void);
int orbita_imap_connect(OrbitaIMAPConnection *, const char *, const char *, const char *);
int orbita_imap_send(OrbitaIMAPConnection *, const unsigned char *, size_t, size_t *);
int orbita_imap_receive(OrbitaIMAPConnection *, unsigned char *, size_t, size_t *);
void orbita_imap_cancel(OrbitaIMAPConnection *);
void orbita_imap_close(OrbitaIMAPConnection *);
#ifdef ORBITA_WIRE_TEST
void orbita_imap_fixture_ca(OrbitaIMAPConnection *, const char *);
#endif
#endif
