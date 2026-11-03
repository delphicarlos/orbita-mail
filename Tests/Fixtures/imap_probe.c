/* Standalone fixture only: compiled with ORBITA_WIRE_TEST. No real credentials. */
#include "CMailTransport.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static int exchange(OrbitaIMAPConnection *connection, const char *command, const char *tag) {
    size_t offset=0, length=strlen(command);
    while(offset<length) { size_t sent=0; int code=orbita_imap_send(connection,(const unsigned char *)command+offset,length-offset,&sent); if(code==81)continue; if(code)return code; offset+=sent; }
    char bytes[65536]; size_t length_read=0;
    while(length_read<sizeof(bytes)-1) {
        size_t count=0; int code=orbita_imap_receive(connection,(unsigned char *)bytes+length_read,sizeof(bytes)-1-length_read,&count);
        if(code==81)continue; if(code)return code; if(!count)return 55;
        length_read+=count; bytes[length_read]=0;
        if(strstr(bytes,tag)){ fwrite(bytes,1,length_read,stdout); return 0; }
    }
    return 63;
}
int main(int argc,char **argv) {
    if(argc!=3)return 2;
    OrbitaIMAPConnection *connection=orbita_imap_create();
    if(strlen(argv[2]))orbita_imap_fixture_ca(connection,argv[2]);
    int code=orbita_imap_connect(connection,argv[1],"fixture","synthetic");
    if(!code)code=exchange(connection,"ORBSELECT SELECT INBOX\r\n","ORBSELECT OK");
    if(!code)code=exchange(connection,"ORBFETCH UID FETCH 7 (UID BODY.PEEK[])\r\n","ORBFETCH OK");
    orbita_imap_close(connection); return code;
}
