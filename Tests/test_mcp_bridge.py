#!/usr/bin/env python3
"""Drive the MCP bridge over stdio against a fake app socket; no app or VPN involved."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / 'Tools/mcp/wiretunnels-mcp.mjs'


def serve(path, seen):
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(4)

    def loop():
        while True:
            try:
                client, _ = server.accept()
            except OSError:
                return
            request = json.loads(client.makefile().readline())
            seen.append(request)
            if request['tool'] == 'connect':
                reply = {'ok': False, 'error': 'Failed to connect: synthetic'}
            else:
                reply = {'ok': True, 'result': [{'name': 'synthetic', 'active': False}]}
            client.sendall((json.dumps(reply) + '\n').encode())
            client.close()
    threading.Thread(target=loop, daemon=True).start()
    return server


def talk(socket_path, requests):
    process = subprocess.run(
        ['node', str(BRIDGE)], input=''.join(json.dumps(r) + '\n' for r in requests),
        capture_output=True, text=True, timeout=60, env={**os.environ, 'WIRETUNNELS_SOCKET': socket_path})
    return {reply['id']: reply for reply in map(json.loads, process.stdout.splitlines())}


def call(request_id, name, arguments=None):
    return {'jsonrpc': '2.0', 'id': request_id, 'method': 'tools/call',
            'params': {'name': name, 'arguments': arguments or {}}}


def main():
    if not shutil.which('node'):
        print('SKIP: node is not installed, MCP bridge not exercised')
        return
    with tempfile.TemporaryDirectory(prefix='wt-mcp-') as directory:
        path = str(Path(directory) / 's.sock')
        seen = []
        server = serve(path, seen)
        replies = talk(path, [
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26'}},
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
            call(3, 'list_tunnels'),
            call(4, 'connect', {'tunnel': 'synthetic'}),
            call(5, 'no_such_tool'),
            call(6, 'system_network'),
            {'jsonrpc': '2.0', 'id': 7, 'method': 'nope'},
        ])
        server.close()
        assert replies[1]['result']['protocolVersion'] == '2025-03-26', 'initialize must echo the client protocol'
        names = {tool['name'] for tool in replies[2]['result']['tools']}
        assert {'connect', 'disconnect', 'list_tunnels', 'get_log', 'system_dns', 'system_network'} <= names
        assert json.loads(replies[3]['result']['content'][0]['text'])[0]['name'] == 'synthetic'
        assert seen[0] == {'tool': 'list_tunnels', 'args': {}}, 'tool request must reach the app socket'
        assert seen[1] == {'tool': 'connect', 'args': {'tunnel': 'synthetic'}}
        assert replies[4]['result']['isError'] and 'synthetic' in replies[4]['result']['content'][0]['text']
        assert replies[5]['result']['isError'], 'unknown tool must be a tool error'
        assert 'utun' in json.loads(replies[6]['result']['content'][0]['text']), 'system_network must answer without the app'
        assert replies[7]['error']['code'] == -32601
        missing = talk(str(Path(directory) / 'absent.sock'), [call(1, 'list_tunnels')])
        assert missing[1]['result']['isError'] and 'not running' in missing[1]['result']['content'][0]['text']
    print('PASS: MCP bridge lists tools, forwards app calls, reports errors and works without the app for system views')


if __name__ == '__main__':
    main()
