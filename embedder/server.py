"""RememBear's embedder: EmbeddingGemma 2 on this Mac's GPU.

RememBear starts this when it has a screenshot to embed (or `remembear search`
has a question) and talks to it over HTTP on 127.0.0.1, with a token only
RememBear knows. Screenshots arrive in the request body and are never written
anywhere; the model runs here, so nothing leaves the Mac.

It quits after IDLE_SECONDS without a request, as the model holds about 3 GB
while it's loaded. RememBear starts it again next time.

    POST /image   body: a JPEG or PNG       -> {"vector": [768 floats]}
    POST /text    body: {"text": "..."}     -> {"vector": [...]}  (a search query)
    GET  /health                            -> {"ok": true}

On start it prints one line, "READY <port>", once the model is loaded.
"""

import io
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import torch  # noqa: E402
from PIL import Image  # noqa: E402
from sentence_transformers import SentenceTransformer  # noqa: E402

MODEL = os.environ.get("REMEMBEAR_MODEL", "google/embeddinggemma-2")
TOKEN = os.environ["REMEMBEAR_EMBEDDER_TOKEN"]
IDLE_SECONDS = float(os.environ.get("REMEMBEAR_EMBEDDER_IDLE", "600"))
# Screenshots are shrunk to this on their longest side: about 0.2 s each on
# an M5, against 0.6 s at 1024, and plenty for what a window looks like.
MAX_SIDE = 768
MAX_BODY = 30 * 1024 * 1024

device = "mps" if torch.backends.mps.is_available() else "cpu"
model = SentenceTransformer(MODEL, device=device, model_kwargs={"torch_dtype": torch.float16 if device == "mps" else torch.float32})
# One request at a time on the GPU.
lock = threading.Lock()
last_used = time.monotonic()


def embed_image(data: bytes) -> list[float]:
    image = Image.open(io.BytesIO(data)).convert("RGB")
    image.thumbnail((MAX_SIDE, MAX_SIDE))
    with lock:
        vector = model.encode([image], normalize_embeddings=True)[0]
    return vector.astype("float32").tolist()


def embed_text(text: str) -> list[float]:
    # The model's own search-query prompt ("task: search result | query: ").
    with lock:
        vector = model.encode([text], prompt_name="query", normalize_embeddings=True)[0]
    return vector.astype("float32").tolist()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # nothing about requests goes to stderr
        pass

    def reply(self, status: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self) -> bool:
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.reply(401, {"error": "unauthorised"})
            return False
        return True

    def do_GET(self):
        if not self.authorised():
            return
        self.reply(200, {"ok": True}) if self.path == "/health" else self.reply(404, {"error": "not found"})

    def do_POST(self):
        global last_used
        if not self.authorised():
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self.reply(400, {"error": "bad length"})
            return
        body = self.rfile.read(length)
        last_used = time.monotonic()
        try:
            if self.path == "/image":
                self.reply(200, {"vector": embed_image(body)})
            elif self.path == "/text":
                self.reply(200, {"vector": embed_text(json.loads(body)["text"])})
            else:
                self.reply(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            self.reply(500, {"error": str(e)[:300]})
        last_used = time.monotonic()


def quit_when_idle(server: ThreadingHTTPServer):
    while True:
        time.sleep(15)
        if time.monotonic() - last_used > IDLE_SECONDS:
            server.shutdown()
            return


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=quit_when_idle, args=(server,), daemon=True).start()
    print(f"READY {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
