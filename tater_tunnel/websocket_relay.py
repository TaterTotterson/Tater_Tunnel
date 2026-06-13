from __future__ import annotations

import base64
import hashlib
import secrets
from typing import Any


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OPCODE_CONTINUATION = 0x0
OPCODE_TEXT = 0x1
OPCODE_BINARY = 0x2
OPCODE_CLOSE = 0x8
OPCODE_PING = 0x9
OPCODE_PONG = 0xA


class WebSocketProtocolError(Exception):
    pass


def create_websocket_key() -> str:
    return base64.b64encode(secrets.token_bytes(16)).decode("ascii")


def websocket_accept_key(key: str) -> str:
    digest = hashlib.sha1(f"{key.strip()}{WEBSOCKET_GUID}".encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def recv_exact(sock: Any, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise EOFError("WebSocket connection closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(sock: Any, masked: bool | None = None) -> dict[str, Any]:
    first, second = recv_exact(sock, 2)
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    has_mask = bool(second & 0x80)
    length = second & 0x7F

    if masked is not None and has_mask != masked:
        expected = "masked" if masked else "unmasked"
        raise WebSocketProtocolError(f"Expected {expected} WebSocket frame")

    if length == 126:
        length = int.from_bytes(recv_exact(sock, 2), "big")
    elif length == 127:
        length = int.from_bytes(recv_exact(sock, 8), "big")

    mask_key = recv_exact(sock, 4) if has_mask else b""
    payload = recv_exact(sock, length) if length else b""
    if has_mask and payload:
        payload = bytes(byte ^ mask_key[index % 4] for index, byte in enumerate(payload))

    return {
        "fin": fin,
        "opcode": opcode,
        "payload": payload,
    }


def write_frame(sock: Any, opcode: int, payload: bytes = b"", fin: bool = True, masked: bool = False) -> None:
    first = (0x80 if fin else 0) | (opcode & 0x0F)
    length = len(payload)
    mask_bit = 0x80 if masked else 0

    if length < 126:
        header = bytes([first, mask_bit | length])
    elif length < 65536:
        header = bytes([first, mask_bit | 126]) + length.to_bytes(2, "big")
    else:
        header = bytes([first, mask_bit | 127]) + length.to_bytes(8, "big")

    if masked:
        mask_key = secrets.token_bytes(4)
        masked_payload = bytes(byte ^ mask_key[index % 4] for index, byte in enumerate(payload))
        sock.sendall(header + mask_key + masked_payload)
        return

    sock.sendall(header + payload)


def frame_to_payload(frame: dict[str, Any]) -> dict[str, Any]:
    return {
        "fin": bool(frame.get("fin", True)),
        "opcode": int(frame.get("opcode", OPCODE_BINARY)),
        "bodyBase64": base64.b64encode(frame.get("payload") or b"").decode("ascii"),
    }


def payload_to_frame(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "fin": bool(payload.get("fin", True)),
        "opcode": int(payload.get("opcode", OPCODE_BINARY)),
        "payload": base64.b64decode(str(payload.get("bodyBase64") or "").encode("ascii")),
    }
