#!/usr/bin/env python3
"""把本机回环代理(默认 127.0.0.1:7890)按需转发到某个局域网地址上。

用途: 让 USB 直连的平板借用 PC 的代理下载 GitHub/Flutter/pub 资源
(平板自己只能直连 USTC 镜像)。只监听指定 bind 地址, 不暴露给整个局域网。

用法: python3 lan_proxy_forward.py [--bind 192.168.7.9] [--port 7890] [--upstream 127.0.0.1:7890]
"""
import argparse
import asyncio


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer, upstream_host, upstream_port):
    try:
        up_reader, up_writer = await asyncio.open_connection(upstream_host, upstream_port)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(
        pipe(client_reader, up_writer),
        pipe(up_reader, client_writer),
    )


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="192.168.7.9")
    ap.add_argument("--port", type=int, default=7890)
    ap.add_argument("--upstream", default="127.0.0.1:7890")
    args = ap.parse_args()
    host, port = args.upstream.split(":")
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, host, int(port)), args.bind, args.port
    )
    print(f"forwarding {args.bind}:{args.port} -> {args.upstream}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
