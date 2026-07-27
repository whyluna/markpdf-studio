#!/usr/bin/env python3
"""本地 AI Provider mock（无真实 Key 的链路验证）：
同时仿真 OpenAI 兼容协议（POST /v1/chat/completions）与
Anthropic Messages 协议（POST /v1/messages），流式/非流式均支持。

用法：python3 scripts/mock_ai_server.py [端口，默认 8787]
配合：AI_MOCK_BASE_URL=http://127.0.0.1:8787 xcodebuild test -only-testing:MarkPDFTests/AIIntegrationTests
（xcodebuild 会清洗环境变量，故启动时同步写 /tmp/markpdf-ai-mock.url 作为备用发现通道）
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BAD_KEY = "bad-key"


def sse(events):
    """events: [(name|None, data_str)] → SSE 字节流"""
    out = []
    for name, data in events:
        if name:
            out.append(f"event: {name}\n")
        out.append(f"data: {data}\n\n")
    return "".join(out).encode()


def openai_chunk(delta, finish=None):
    return json.dumps({
        "id": "chatcmpl-mock", "object": "chat.completion.chunk",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }, ensure_ascii=False)


def anthropic_event(event_type, **fields):
    payload = {"type": event_type}
    payload.update(fields)
    return json.dumps(payload, ensure_ascii=False)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _reply(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")

        if self.path == "/v1/chat/completions":
            auth = self.headers.get("Authorization", "")
            key = auth.removeprefix("Bearer ").strip()
            if not key or key == BAD_KEY:
                self._reply(401, json.dumps(
                    {"error": {"message": "invalid api key", "type": "auth_error"}}).encode())
                return
            has_tool_result = any(m.get("role") == "tool" for m in body.get("messages", []))
            if body.get("stream"):
                if body.get("tools") and not has_tool_result:
                    # 工具轮：请求 workspace_search（arguments 分片验证重组器）
                    events = [
                        (None, openai_chunk({"role": "assistant", "content": ""})),
                        (None, openai_chunk({"tool_calls": [{
                            "index": 0, "id": "call_mock_1", "type": "function",
                            "function": {"name": "workspace_search", "arguments": ""}}]})),
                        (None, openai_chunk({"tool_calls": [{
                            "index": 0, "function": {"arguments": "{\"query\":"}}]})),
                        (None, openai_chunk({"tool_calls": [{
                            "index": 0, "function": {"arguments": "\"attention\"}"}}]})),
                        (None, openai_chunk({}, finish="tool_calls")),
                        (None, "[DONE]"),
                    ]
                else:
                    events = [
                        (None, openai_chunk({"role": "assistant", "content": ""})),
                        (None, openai_chunk({"content": "你"})),
                        (None, openai_chunk({"content": "好"})),
                        (None, openai_chunk({}, finish="stop")),
                        (None, "[DONE]"),
                    ]
                self._reply(200, sse(events), "text/event-stream")
            else:
                self._reply(200, json.dumps({
                    "id": "chatcmpl-mock", "object": "chat.completion",
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant", "content": "pong"}}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                }).encode())
            return

        if self.path == "/v1/messages":
            key = self.headers.get("x-api-key", "")
            if not key or key == BAD_KEY:
                self._reply(401, json.dumps(
                    {"type": "error", "error": {"type": "authentication_error",
                                                "message": "invalid x-api-key"}}).encode())
                return
            if not self.headers.get("anthropic-version"):
                self._reply(400, json.dumps(
                    {"type": "error", "error": {"type": "invalid_request_error",
                                                "message": "anthropic-version required"}}).encode())
                return
            def has_anthropic_tool_result():
                for m in body.get("messages", []):
                    content = m.get("content")
                    if isinstance(content, list) and any(
                            b.get("type") == "tool_result" for b in content):
                        return True
                return False

            if body.get("stream") and body.get("tools") and not has_anthropic_tool_result():
                # 工具轮：tool_use 块 + input_json_delta 分片
                events = [
                    ("message_start", anthropic_event(
                        "message_start",
                        message={"id": "msg_mock", "type": "message", "role": "assistant",
                                 "model": body.get("model", "mock"), "content": [],
                                 "stop_reason": None,
                                 "usage": {"input_tokens": 1, "output_tokens": 0}})),
                    ("content_block_start", anthropic_event(
                        "content_block_start", index=0,
                        content_block={"type": "tool_use", "id": "tu_mock_1",
                                       "name": "workspace_search", "input": {}})),
                    ("content_block_delta", anthropic_event(
                        "content_block_delta", index=0,
                        delta={"type": "input_json_delta", "partial_json": "{\"query\":"})),
                    ("content_block_delta", anthropic_event(
                        "content_block_delta", index=0,
                        delta={"type": "input_json_delta", "partial_json": "\"attention\"}"})),
                    ("content_block_stop", anthropic_event("content_block_stop", index=0)),
                    ("message_delta", anthropic_event(
                        "message_delta", delta={"stop_reason": "tool_use"},
                        usage={"output_tokens": 2})),
                    ("message_stop", anthropic_event("message_stop")),
                ]
                self._reply(200, sse(events), "text/event-stream")
                return
            if body.get("stream"):
                events = [
                    ("message_start", anthropic_event(
                        "message_start",
                        message={"id": "msg_mock", "type": "message", "role": "assistant",
                                 "model": body.get("model", "mock"), "content": [],
                                 "stop_reason": None,
                                 "usage": {"input_tokens": 1, "output_tokens": 0}})),
                    ("content_block_start", anthropic_event(
                        "content_block_start", index=0,
                        content_block={"type": "text", "text": ""})),
                    ("content_block_delta", anthropic_event(
                        "content_block_delta", index=0,
                        delta={"type": "text_delta", "text": "你"})),
                    ("content_block_delta", anthropic_event(
                        "content_block_delta", index=0,
                        delta={"type": "text_delta", "text": "好"})),
                    ("content_block_stop", anthropic_event("content_block_stop", index=0)),
                    ("message_delta", anthropic_event(
                        "message_delta", delta={"stop_reason": "end_turn"},
                        usage={"output_tokens": 2})),
                    ("message_stop", anthropic_event("message_stop")),
                ]
                self._reply(200, sse(events), "text/event-stream")
            else:
                self._reply(200, json.dumps({
                    "id": "msg_mock", "type": "message", "role": "assistant",
                    "model": body.get("model", "mock"),
                    "content": [{"type": "text", "text": "pong"}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                }).encode())
            return

        self._reply(404, b'{"error":"not found"}')


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    with open("/tmp/markpdf-ai-mock.url", "w") as f:
        f.write(f"http://127.0.0.1:{port}")
    print(f"mock AI server on http://127.0.0.1:{port}")
    server.serve_forever()
