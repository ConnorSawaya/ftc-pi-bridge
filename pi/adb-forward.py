#!/usr/bin/env python3
"""Forward ADB from the Mac (USB side) to the Control Hub (Wi-Fi side).

The Mac runs `adb connect 10.12.194.1:5555`; every connection is piped to the hub.
Standard library only, so the Pi never needs internet.
"""
import asyncio
import socket

LISTEN = ("10.12.194.1", 5555)  # Pi's address on the USB link (rpi-usb-gadget shared mode)
HUB = ("192.168.43.1", 5555)    # Control Hub ADB over Wi-Fi
IP_FREEBIND = getattr(socket, "IP_FREEBIND", 15)  # lets us bind before usb0 has its address


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def handle(mac_reader, mac_writer):
    try:
        hub_reader, hub_writer = await asyncio.wait_for(asyncio.open_connection(*HUB), 5)
    except (OSError, asyncio.TimeoutError):
        mac_writer.close()  # hub off or out of range: adb on the Mac just sees a refused connection
        return
    await asyncio.gather(pipe(mac_reader, hub_writer), pipe(hub_reader, mac_writer),
                         return_exceptions=True)


async def main():
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
    sock.bind(LISTEN)  # USB side only, never the robot's Wi-Fi
    server = await asyncio.start_server(handle, sock=sock)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
