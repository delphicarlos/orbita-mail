#!/usr/bin/env python3
"""Disposable loopback TLS fixtures for the macOS curl mail transport. No real accounts."""
import json, pathlib, socketserver, ssl, subprocess, tempfile, threading, sys

MESSAGE = b'From: fixture@example.com\r\nTo: local@example.com\r\nSubject: Fixture\r\nMessage-ID: <fixture@example.com>\r\n\r\nHello\r\n'

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def handle_error(self, request, address):
        if not isinstance(sys.exception(), ssl.SSLError): super().handle_error(request, address)

class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        if not self.server.starttls:
            self.request = self.server.tls.wrap_socket(self.request, server_side=True)
        super().setup()
    def send(self, value):
        self.wfile.write(value.encode() if isinstance(value, str) else value); self.wfile.flush()
    def handle(self):
        proto = self.server.proto
        self.send({'imap':'* OK fixture\r\n', 'pop3':'+OK fixture\r\n', 'smtp':'220 fixture ESMTP\r\n'}[proto])
        while True:
            line = self.rfile.readline()
            if not line: return
            text = line.decode().strip(); pieces = text.split(' ', 1)
            tag, command = (pieces[0], pieces[1]) if proto == 'imap' and len(pieces) == 2 else ('', text)
            upper = command.upper()
            # Never capture authentication material, even synthetic values.
            self.server.commands.append(upper.split(' ',1)[0] if upper.startswith(('LOGIN ', 'AUTH ', 'USER ', 'PASS ')) else upper)
            if upper in ('STARTTLS', 'STLS'):
                self.send(f'{tag} OK TLS\r\n' if proto == 'imap' else ('220 TLS\r\n' if proto == 'smtp' else '+OK TLS\r\n'))
                self.connection = self.request = self.server.tls.wrap_socket(self.request, server_side=True)
                self.rfile = self.connection.makefile('rb'); self.wfile = self.connection.makefile('wb')
            elif proto == 'imap':
                if upper == 'CAPABILITY': self.send('* CAPABILITY IMAP4rev1 STARTTLS\r\n')
                elif upper.startswith('SELECT '): self.send('* 1 EXISTS\r\n* OK [UIDVALIDITY 50] fixture\r\n')
                elif upper.startswith('STATUS '): self.send('* STATUS INBOX (MESSAGES 400 UNSEEN 51)\r\n' if 'UNSEEN' in upper else '* STATUS INBOX (UIDVALIDITY 50)\r\n')
                elif upper.startswith('LIST '): self.send('* LIST (\\Sent) "/" "Sent"\r\n')
                elif upper.startswith('UID SEARCH '): self.send('* SEARCH 7\r\n')
                elif upper.startswith('UID FETCH '): self.send(b'* 1 FETCH (UID 7 FLAGS (\\Seen) BODY[] {' + str(len(MESSAGE)).encode() + b'}\r\n' + MESSAGE + b')\r\n')
                elif upper.startswith('APPEND '):
                    size = int(command.rsplit('{',1)[1].rstrip('}'))
                    self.send('+ ready\r\n'); self.server.payload = self.rfile.read(size); self.rfile.readline()
                elif upper == 'LOGOUT': self.send('* BYE\r\n'); self.send(f'{tag} OK bye\r\n'); return
                elif not upper.startswith(('LOGIN ', 'UID STORE ', 'UID MOVE ', 'CREATE ')): raise AssertionError(command)
                self.send(f'{tag} OK complete\r\n')
            elif proto == 'pop3':
                if upper == 'CAPA': self.send('+OK\r\nUSER\r\nSTLS\r\nUIDL\r\nTOP\r\n.\r\n')
                elif upper == 'UIDL': self.send('+OK\r\n1 stable-7\r\n.\r\n')
                elif upper.startswith(('TOP ', 'RETR ')): self.send(b'+OK\r\n' + MESSAGE + b'.\r\n')
                elif upper == 'QUIT': self.send('+OK\r\n'); return
                else: self.send('+OK\r\n')
            else:
                if upper.startswith(('EHLO ', 'HELO ')): self.send('250-fixture\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n')
                elif upper.startswith('AUTH '):
                    if len(upper.split()) < 3: self.send('334 \r\n'); self.rfile.readline()
                    self.send('235 authenticated\r\n')
                elif upper == 'DATA':
                    self.send('354 continue\r\n'); body = b''
                    while (value := self.rfile.readline()) != b'.\r\n': body += value
                    self.server.payload = body; self.send('250 queued\r\n')
                elif upper == 'QUIT': self.send('221 bye\r\n'); return
                else: self.send('250 OK\r\n')

with tempfile.TemporaryDirectory(prefix='orbita-wire-') as directory:
    root = pathlib.Path(directory); ca = root/'cert.pem'; key = root/'key.pem'
    config = root/'openssl.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n')
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(ca),'-days','1','-config',str(config)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(ca,key)
    results = []
    probe = root/'imap-probe'
    project = pathlib.Path(__file__).resolve().parent.parent
    subprocess.run(['xcrun','clang','-DORBITA_WIRE_TEST','-I'+str(project/'Sources/CMailTransport/include'),str(project/'Sources/CMailTransport/CMailTransport.c'),str(project/'Tests/Fixtures/imap_probe.c'),'-lcurl','-o',str(probe)],check=True)
    def run(proto, command=None, path='/', upload=False, starttls=False, expected=None, fail=False, untrusted=False):
        with Server(('127.0.0.1',0),Handler) as server:
            server.proto=proto; server.tls=tls; server.starttls=starttls; server.commands=[]; server.payload=None
            thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
            scheme=proto + ('' if starttls else 's'); port=server.server_address[1]
            options=f'silent\nshow-error\nssl-reqd\nmax-time = 8\nproxy = ""\nurl = "{scheme}://localhost:{port}{path}"\nuser = "fixture:synthetic"\ncacert = "{ca}"\n'
            if proto == 'imap': options+='include\n'
            if command: options+=f'request = "{command}"\n'
            if upload:
                file=root/'message'; file.write_bytes(MESSAGE); options+=f'upload-file = "{file}"\n'
                if proto=='smtp': options+='mail-from = "fixture@example.com"\nmail-rcpt = "local@example.com"\n'
            native = proto=='imap' and command and command.startswith('UID FETCH')
            if native:
                reply=subprocess.run([str(probe),f'{scheme}://localhost:{port}/','' if untrusted else str(ca)],capture_output=True)
                if not fail and not untrusted:
                    assert MESSAGE in reply.stdout, repr(reply.stdout)
                    assert 'LOGIN' in server.commands, 'Native connection did not authenticate'
            else:
                reply=subprocess.run(['/usr/bin/curl','--disable','--config','-'],input=options.encode(),capture_output=True)
            server.shutdown()
            if fail or untrusted: assert reply.returncode != 0, 'Invalid identity or certificate accepted'
            else:
                assert reply.returncode==0, reply.stderr.decode()
                if expected is not None: assert expected in reply.stdout, repr(reply.stdout)
                if upload: assert server.payload==MESSAGE,(proto,server.payload)
                if proto=='smtp': assert 'AUTH' in server.commands, 'SMTP did not authenticate'
            results.append({'protocol':proto,'startTLS':starttls,'operation':('reject untrusted TLS' if untrusted else command or 'upload'),'passed':True})
            if command and command.startswith('UID FETCH') and not untrusted:
                assert b'ORBFETCH OK' in reply.stdout
    run('imap','STATUS INBOX (UIDVALIDITY)',expected=b'* STATUS INBOX (UIDVALIDITY 50)')
    run('imap','STATUS INBOX (UNSEEN MESSAGES)',expected=b'UNSEEN 51')
    run('imap','CREATE ClientsFixture')
    run('imap','LIST \\"\\" \\"*\\"',expected=b'* LIST')
    run('imap','UID SEARCH ALL','/INBOX;UIDVALIDITY=50',expected=b'* SEARCH 7')
    run('imap','UID FETCH 7 (UID BODY.PEEK[])','/INBOX;UIDVALIDITY=50',expected=b'* 1 FETCH')
    run('imap','UID SEARCH ALL','/INBOX;UIDVALIDITY=99',fail=True)
    run('imap','UID FETCH 7 (UID BODY.PEEK[])','/INBOX;UIDVALIDITY=50',starttls=True,expected=MESSAGE)
    run('imap','UID FETCH 7 (UID BODY.PEEK[])',untrusted=True)
    run('imap',path='/Sent',upload=True)
    run('imap','UID SEARCH ALL','/INBOX;UIDVALIDITY=50',starttls=True,expected=b'* SEARCH 7')
    run('pop3','UIDL',expected=b'1 stable-7')
    run('pop3','TOP 1 0',expected=b'Subject: Fixture')
    run('pop3','RETR 1',starttls=True,expected=b'Subject: Fixture')
    run('smtp','NOOP')
    run('smtp',upload=True,starttls=True)
    report={'fixture':'loopback only; ephemeral trusted certificate; synthetic credentials','checks':results}
    destination=pathlib.Path(__file__).resolve().parent.parent/'evidence/mail-wire.json'; destination.write_text(json.dumps(report,indent=2)+'\n')
    print(f'{len(results)} protocol checks passed')
