import http.client
import json
import threading
import unittest
from unittest.mock import Mock, patch
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from bridge import Media, Handler, Unavailable, TORRSERVER, DATA, VLC

HASH = 'a' * 40

class Tests(unittest.TestCase):
    def test_malformed(self):
        media = Media({})
        for value in (None, '', '../x', HASH + '&index=1', 123):
            with self.assertRaises(ValueError):
                media.dispatch({'action': 'files', 'id': value})
        for value in ('0', '-1', '1&x=y', '１２', None):
            with self.assertRaises(ValueError):
                Media({'lampa_adapter': 'https://adapter.test'}).dispatch({'action': 'card', 'tmdb': value, 'kind': 'tv'})

    def test_no_history(self):
        with self.assertRaises(Unavailable):
            Media({}).dispatch({'action': 'resume'})
        with self.assertRaises(Unavailable):
            Media({'lampa_adapter': 'https://adapter.test'}, fetch=lambda u: {}).dispatch({'action': 'resume'})

    def test_adapter_escape(self):
        fetch = Mock(return_value={'url': 'lampa://verified/card?id=123'})
        result = Media({'lampa_adapter': 'https://adapter.test/chooser?verified=1'}, fetch).dispatch(
            {'action': 'card', 'kind': 'tv', 'tmdb': '123'})
        self.assertEqual(result['url'], 'lampa://verified/card?id=123')
        self.assertEqual(parse_qs(urlsplit(fetch.call_args.args[0]).query)['tmdb'], ['123'])

    def test_newest_not_order(self):
        rows = [{'hash': HASH, 'added': 20}, {'hash': 'b'*40, 'added': 10}]
        media = Media({'authoritative_added_field': 'added'}, lambda *a: rows)
        self.assertEqual(media.newest(), HASH)
        rows[1]['added'] = 20
        with self.assertRaises(Unavailable): media.newest()
        rows[1].pop('added')
        with self.assertRaises(Unavailable): media.newest()
        with self.assertRaises(Unavailable): Media({}, lambda *a: rows).newest()

    def test_explicit_file_vlc(self):
        spawn = Mock()
        media = Media({}, lambda *a: {'hash': HASH, 'file_stats': [{'id': 2, 'path': 'synthetic & file'}]}, spawn)
        for index in (None, 1, True, '2'):
            with self.assertRaises(ValueError): media.play(HASH, index)
        media.play(HASH, 2)
        args = spawn.call_args.args[0]
        self.assertEqual(args[:2], [VLC, '--'])
        self.assertFalse(spawn.call_args.kwargs['shell'])
        self.assertEqual(parse_qs(urlsplit(args[2]).query)['index'], ['2'])

    def test_upstream_failure(self):
        media = Media({}, Mock(side_effect=OSError('synthetic')))
        with self.assertRaises(OSError): media.dispatch({'action': 'torrents'})
        with self.assertRaises(Unavailable): Media({}, lambda *a: {}).torrents()

    @patch('socket.socket')
    def test_restart_unowned_boundary(self, socket):
        socket.return_value.__enter__.return_value.connect_ex.return_value = 0
        spawn = Mock()
        with self.assertRaises(Unavailable): Media({'restart_enabled': True}, spawn=spawn).restart()
        spawn.assert_not_called()

    @patch('bridge.time.sleep')
    @patch('bridge.Path.is_file', return_value=True)
    @patch('socket.socket')
    def test_restart_exact_argv_and_ready(self, socket, exists, sleep):
        socket.return_value.__enter__.return_value.connect_ex.return_value = 1
        process = Mock(); process.poll.return_value = None
        spawn = Mock(return_value=process)
        media = Media({'restart_enabled': True}, lambda *a: [], spawn)
        media.restart()
        argv = spawn.call_args.args[0]
        self.assertEqual(argv, [TORRSERVER, '--path', DATA, '--port', '8090', '--ip', '127.0.0.1'])
        self.assertFalse(spawn.call_args.kwargs['shell'])
        process.poll.return_value = 1
        with self.assertRaises(Unavailable): media.restart()

    @patch('bridge.time.sleep')
    @patch('bridge.Path.is_file', return_value=True)
    @patch('socket.socket')
    def test_restart_timeout_not_success(self, socket, exists, sleep):
        socket.return_value.__enter__.return_value.connect_ex.return_value = 1
        process = Mock(); process.poll.return_value = None
        media = Media({'restart_enabled': True}, Mock(side_effect=OSError()), Mock(return_value=process))
        with self.assertRaises(Unavailable): media.restart()

    def test_auth_and_request_boundary(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.token = 'x'*32; server.media = Mock()
        server.media.dispatch.return_value = {'lampa': False}
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            for token, body, expected in [('', {}, 401), ('Bearer '+server.token, [], 400),
                                           ('Bearer '+server.token, {'action': 'capabilities'}, 200)]:
                conn = http.client.HTTPConnection(*server.server_address)
                conn.request('POST', '/actions', json.dumps(body), {'Authorization': token})
                response = conn.getresponse(); response.read()
                self.assertEqual(response.status, expected); conn.close()
            self.assertEqual(server.media.dispatch.call_count, 1)
        finally:
            server.shutdown(); server.server_close(); thread.join()

if __name__ == '__main__': unittest.main()
