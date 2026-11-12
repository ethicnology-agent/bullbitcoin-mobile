#!/usr/bin/env python3
"""SOCKS5 fixture restricted to the local RecoverBull test service."""

import asyncio
import contextlib
import signal


async def serve(reader, writer):
    upstream = None
    try:
        version, count = await asyncio.wait_for(reader.readexactly(2), 5)
        methods = await reader.readexactly(count)
        if version != 5 or 0 not in methods:
            return
        writer.write(b"\x05\x00")
        await writer.drain()
        request = await reader.readexactly(4)
        if request != b"\x05\x01\x00\x03":
            return
        length = (await reader.readexactly(1))[0]
        host = (await reader.readexactly(length)).decode("ascii")
        port = int.from_bytes(await reader.readexactly(2), "big")
        if host != "regtest.recoverbull.onion" or port != 3000:
            writer.write(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
            return
        remote, upstream = await asyncio.wait_for(asyncio.open_connection("recoverbull", 3000), 5)
        writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await writer.drain()

        async def copy(source, destination):
            while data := await asyncio.wait_for(source.read(16384), 120):
                destination.write(data)
                await destination.drain()

        tasks = [asyncio.create_task(copy(reader, upstream)),
                 asyncio.create_task(copy(remote, writer))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    except (OSError, ValueError, asyncio.IncompleteReadError, TimeoutError):
        pass
    finally:
        for connection in (writer, upstream):
            if connection is not None:
                connection.close()
                with contextlib.suppress(OSError):
                    await connection.wait_closed()


async def main():
    stopped = asyncio.Event()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stopped.set)
    server = await asyncio.start_server(serve, "0.0.0.0", 9051)
    async with server:
        await stopped.wait()


if __name__ == "__main__":
    asyncio.run(main())
