"""Repassa 127.0.0.1:<porta> para o servidor do app no iPhone por um endereço fixo (ex.: o IPv6 do cabo USB).

    python3 analysis/runtime/iphone_proxy.py "fe80::6445:57ff:fe0c:1aa5%en9" 8080 18080

Existe porque o nome mDNS `iPhone-de-David.local` pode resolver para vários IPv6, alguns sem rota, e o cliente do
`bfcl-eval` (`httpcore2`) não aceita endereço com zona (`%en9`). Com o repasse, runner e BFCL usam
`http://127.0.0.1:18080`. Só copia bytes; não lê nem altera as requisições.
"""
import asyncio
import socket
import sys


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


async def main(host, port, local):
    info = socket.getaddrinfo(host, port, socket.AF_INET6, socket.SOCK_STREAM)[0][4]

    async def handle(client_reader, client_writer):
        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            sock.setblocking(False)
            await asyncio.get_running_loop().sock_connect(sock, info)
            remote_reader, remote_writer = await asyncio.open_connection(sock=sock)
        except OSError:
            client_writer.close()
            return
        await asyncio.gather(pipe(client_reader, remote_writer), pipe(remote_reader, client_writer))

    server = await asyncio.start_server(handle, "127.0.0.1", local)
    print(f"127.0.0.1:{local} -> [{host}]:{port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3])))
