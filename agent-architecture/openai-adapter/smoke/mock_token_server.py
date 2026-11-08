"""Мок бэкенда подписки для проверки обновления токена: /oauth/token и /responses.

Выдаёт токены на обмене refresh_token и принимает на /responses только их; любой другой
токен получает 401 token_expired. Запуск: mock_token_server.py <порт> <журнал>
"""
import json,sys,time,base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
def jwt(iat): 
    e=lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
    return f"{e({'alg':'none'})}.{e({'iat':int(iat),'exp':int(iat+864000)})}.s"
valid=set(); log=open(sys.argv[2],"a")
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get("content-length",0)))
        if self.path=="/oauth/token":
            t=jwt(time.time()); valid.add(t)
            out=json.dumps({"access_token":t,"id_token":t,"refresh_token":"r2"}).encode(); log.write("oauth refresh\n"); log.flush()
            self.send_response(200); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(out))); self.end_headers(); self.wfile.write(out); return
        tok=self.headers.get("authorization","")[7:]
        log.write(f"responses valid={tok in valid}\n"); log.flush()
        if tok not in valid:
            out=json.dumps({"error":{"message":"Provided authentication token is expired.","code":"token_expired"},"status":401}).encode()
            self.send_response(401); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(out))); self.end_headers(); self.wfile.write(out); return
        out=json.dumps({"id":"r","object":"response","created_at":1,"status":"completed","model":"m","output":[{"type":"message","id":"m1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK-РАБОТАЕТ","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}).encode()
        self.send_response(200); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(out))); self.end_headers(); self.wfile.write(out)
ThreadingHTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
