#!/usr/bin/env python3
"""
Kanban Board Server
A simple Python/JSON backend for the Kanban board.
"""

import json
import os
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime
import re

DATA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'kanban_data.json')


def is_admin():
    """Check if running with admin privileges on Windows."""
    try:
        import ctypes
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        return False


def get_local_ips():
    """Get all local IP addresses for network access display."""
    ips = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None):
            # info[4][0] is the IP address
            ip = info[4][0]
            # Only include IPv4 addresses, exclude localhost
            if ':' not in ip and not ip.startswith('127.'):
                if ip not in ips:
                    ips.append(ip)
    except:
        pass
    return ips


def get_computer_name():
    """Get the computer's NETBIOS name."""
    try:
        return socket.gethostname()
    except:
        return None


def validate_color(color):
    """Validate that color is a safe hex or rgb format."""
    if not color:
        return '#6366f1'
    if re.match(r'^#[0-9A-Fa-f]{3}$', color) or re.match(r'^#[0-9A-Fa-f]{6}$', color):
        return color
    if re.match(r'^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(,\s*(0|1|0?\.\d+))?\s*\)$', color):
        return color
    return '#6366f1'


def load_data():
    """Load data from JSON file."""
    if os.path.exists(DATA_PATH):
        try:
            with open(DATA_PATH, 'r', encoding='utf-8') as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return get_default_data()


def get_default_data():
    """Get default data structure."""
    return {
        'columns': [
            {'id': 'todo', 'name': 'To Do', 'position': 0, 'color': '#f472b6'},
            {'id': 'progress', 'name': 'In Progress', 'position': 1, 'color': '#60a5fa'},
            {'id': 'done', 'name': 'Done', 'position': 2, 'color': '#4ade80'}
        ],
        'tags': [
            {'id': 1, 'name': 'Bug', 'color': '#ef4444'},
            {'id': 2, 'name': 'Feature', 'color': '#22c55e'},
            {'id': 3, 'name': 'Enhancement', 'color': '#3b82f6'},
            {'id': 4, 'name': 'Urgent', 'color': '#f97316'},
            {'id': 5, 'name': 'Documentation', 'color': '#8b5cf6'}
        ],
        'cards': {},
        'nextCardId': 1,
        'nextTagId': 6
    }


def save_data(data):
    """Save data to JSON file."""
    with open(DATA_PATH, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)


# Global data store
data = load_data()


class KanbanHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the Kanban API."""

    def log_message(self, format, *args):
        """Log HTTP requests."""
        print(f"[{self.command}] {args[0]}")

    def send_json(self, data, status=200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-XSS-Protection', '1; mode=block')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def send_file(self, filepath):
        """Serve static file."""
        try:
            with open(filepath, 'rb') as f:
                content = f.read()
            self.send_response(200)
            if filepath.endswith('.html'):
                self.send_header('Content-Type', 'text/html')
            elif filepath.endswith('.css'):
                self.send_header('Content-Type', 'text/css')
            elif filepath.endswith('.js'):
                self.send_header('Content-Type', 'application/javascript')
            else:
                self.send_header('Content-Type', 'application/octet-stream')
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def get_body(self):
        """Parse JSON body from request."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            body = self.rfile.read(content_length).decode()
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return {}
        return {}

    def do_GET(self):
        """Handle GET requests."""
        global data
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/' or path == '/index.html':
            html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'index.html')
            self.send_file(html_path)
            return

        if path == '/api/cards':
            self.get_cards()
            return

        if path == '/api/tags':
            self.get_tags()
            return

        if path == '/api/columns':
            self.get_columns()
            return

        if path.startswith('/api/cards/'):
            card_id = path.split('/')[-1]
            self.get_card(card_id)
            return

        self.send_json({'error': 'Not found'}, 404)

    def do_POST(self):
        """Handle POST requests."""
        parsed = urlparse(self.path)
        path = parsed.path
        body = self.get_body()

        if path == '/api/cards':
            self.create_card(body)
            return

        if path == '/api/tags':
            self.create_tag(body)
            return

        if path == '/api/columns':
            self.create_column(body)
            return

        if path.startswith('/api/cards/') and path.endswith('/checklist'):
            card_id = path.split('/')[3]
            self.add_checklist_item(card_id, body)
            return

        self.send_json({'error': 'Not found'}, 404)

    def do_PUT(self):
        """Handle PUT requests."""
        parsed = urlparse(self.path)
        path = parsed.path
        body = self.get_body()

        if path.startswith('/api/cards/') and not path.endswith('/checklist'):
            card_id = path.split('/')[-1]
            self.update_card(card_id, body)
            return

        if path == '/api/cards/bulk-move':
            self.bulk_move_cards(body)
            return

        if path == '/api/reorder':
            self.reorder_cards(body)
            return

        if path == '/api/columns/reorder':
            self.reorder_columns(body)
            return

        if path == '/api/columns/move-cards':
            self.move_cards_to_column(body)
            return

        if path.startswith('/api/columns/'):
            column_id = path.split('/')[-1]
            self.update_column(column_id, body)
            return

        if path.startswith('/api/checklist/'):
            item_id = path.split('/')[-1]
            self.update_checklist_item(item_id, body)
            return

        self.send_json({'error': 'Not found'}, 404)

    def do_DELETE(self):
        """Handle DELETE requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        if path.startswith('/api/cards/'):
            card_id = path.split('/')[-1]
            self.delete_card(card_id)
            return

        if path.startswith('/api/tags/'):
            tag_id = path.split('/')[-1]
            self.delete_tag(tag_id)
            return

        if path.startswith('/api/columns/'):
            column_id = path.split('/')[-1]
            self.delete_column(column_id)
            return

        if path.startswith('/api/checklist/'):
            item_id = path.split('/')[-1]
            self.delete_checklist_item(item_id)
            return

        self.send_json({'error': 'Not found'}, 404)

    # Column Methods
    def get_columns(self):
        """Get all columns."""
        global data
        columns = []
        for col in data['columns']:
            col_copy = col.copy()
            col_copy['card_count'] = sum(1 for c in data['cards'].values() if c.get('column') == col['id'])
            columns.append(col_copy)
        self.send_json(columns)

    def create_column(self, body):
        """Create a new column."""
        global data
        import uuid
        col_id = body.get('id', str(uuid.uuid4())[:8])
        name = body.get('name', 'New Column')
        color = validate_color(body.get('color'))
        
        max_pos = max((col['position'] for col in data['columns']), default=-1)
        
        new_col = {
            'id': col_id,
            'name': name,
            'position': max_pos + 1,
            'color': color
        }
        data['columns'].append(new_col)
        save_data(data)
        
        new_col['card_count'] = 0
        self.send_json(new_col, 201)

    def update_column(self, column_id, body):
        """Update a column."""
        global data
        for col in data['columns']:
            if col['id'] == column_id:
                if 'name' in body:
                    col['name'] = body['name']
                if 'color' in body:
                    col['color'] = validate_color(body['color'])
                if 'position' in body:
                    col['position'] = body['position']
                save_data(data)
                col_copy = col.copy()
                col_copy['card_count'] = sum(1 for c in data['cards'].values() if c.get('column') == column_id)
                self.send_json(col_copy)
                return
        self.send_json({'error': 'Column not found'}, 404)

    def delete_column(self, column_id):
        """Delete a column."""
        global data
        card_count = sum(1 for c in data['cards'].values() if c.get('column') == column_id)
        if card_count > 0:
            self.send_json({'error': 'Column has cards', 'card_count': card_count}, 400)
            return
        data['columns'] = [col for col in data['columns'] if col['id'] != column_id]
        save_data(data)
        self.send_json({'success': True})

    def reorder_columns(self, body):
        """Reorder columns."""
        global data
        for item in body:
            for col in data['columns']:
                if col['id'] == item['id']:
                    col['position'] = item['position']
                    break
        save_data(data)
        self.send_json({'success': True})

    def move_cards_to_column(self, body):
        """Move all cards from one column to another."""
        global data
        from_col = body.get('from_column')
        to_col = body.get('to_column')
        for card in data['cards'].values():
            if card.get('column') == from_col:
                card['column'] = to_col
        save_data(data)
        self.send_json({'success': True})

    # Tag Methods
    def get_tags(self):
        """Get all tags."""
        global data
        self.send_json(data['tags'])

    def create_tag(self, body):
        """Create a new tag."""
        global data
        name = body.get('name', 'New Tag')
        color = validate_color(body.get('color'))
        
        # Check for duplicate
        for tag in data['tags']:
            if tag['name'] == name:
                self.send_json({'error': 'Tag already exists'}, 400)
                return
        
        new_tag = {
            'id': data['nextTagId'],
            'name': name,
            'color': color
        }
        data['tags'].append(new_tag)
        data['nextTagId'] += 1
        save_data(data)
        self.send_json(new_tag, 201)

    def delete_tag(self, tag_id):
        """Delete a tag."""
        global data
        tag_id = int(tag_id)
        data['tags'] = [tag for tag in data['tags'] if tag['id'] != tag_id]
        # Remove tag from cards
        for card in data['cards'].values():
            if 'tags' in card:
                card['tags'] = [t for t in card['tags'] if t != tag_id]
        save_data(data)
        self.send_json({'success': True})

    # Card Methods
    def get_cards(self):
        """Get all cards."""
        global data
        cards = {}
        for card_id, card in data['cards'].items():
            card_copy = card.copy()
            # Expand tag IDs to tag objects
            card_copy['tags'] = [
                {'id': tag['id'], 'name': tag['name'], 'color': tag['color']}
                for tag in data['tags']
                if tag['id'] in card.get('tags', [])
            ]
            cards[card_id] = card_copy
        self.send_json(cards)

    def get_card(self, card_id):
        """Get a single card."""
        global data
        card = data['cards'].get(card_id)
        if not card:
            self.send_json({'error': 'Card not found'}, 404)
            return
        card_copy = card.copy()
        card_copy['tags'] = [
            {'id': tag['id'], 'name': tag['name'], 'color': tag['color']}
            for tag in data['tags']
            if tag['id'] in card.get('tags', [])
        ]
        self.send_json(card_copy)

    def create_card(self, body):
        """Create a new card."""
        global data
        column = body.get('column', 'todo')
        
        # Get max position in column
        max_pos = max(
            (c['position'] for c in data['cards'].values() if c.get('column') == column),
            default=-1
        )
        
        card_id = str(data['nextCardId'])
        new_card = {
            'id': card_id,
            'title': body.get('title', 'New Card'),
            'description': body.get('description', ''),
            'column': column,
            'position': max_pos + 1,
            'start_date': body.get('start_date'),
            'end_date': body.get('end_date'),
            'created_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'tags': body.get('tags', []),
            'checklist': []
        }
        
        # Add checklist items if provided
        if 'checklist' in body:
            for idx, item in enumerate(body['checklist']):
                new_card['checklist'].append({
                    'id': int(card_id) * 1000 + idx + 1,
                    'text': item.get('text', ''),
                    'completed': item.get('completed', 0),
                    'position': idx
                })
        
        data['cards'][card_id] = new_card
        data['nextCardId'] += 1
        save_data(data)
        
        card_copy = new_card.copy()
        card_copy['tags'] = [
            {'id': tag['id'], 'name': tag['name'], 'color': tag['color']}
            for tag in data['tags']
            if tag['id'] in new_card.get('tags', [])
        ]
        self.send_json(card_copy, 201)

    def update_card(self, card_id, body):
        """Update a card."""
        global data
        card = data['cards'].get(card_id)
        if not card:
            self.send_json({'error': 'Card not found'}, 404)
            return
        
        if 'title' in body:
            card['title'] = body['title']
        if 'description' in body:
            card['description'] = body['description']
        if 'column' in body:
            card['column'] = body['column']
        if 'position' in body:
            card['position'] = body['position']
        if 'start_date' in body:
            card['start_date'] = body['start_date']
        if 'end_date' in body:
            card['end_date'] = body['end_date']
        if 'tags' in body:
            card['tags'] = body['tags']
        if 'checklist' in body:
            card['checklist'] = body['checklist']
        
        save_data(data)
        
        card_copy = card.copy()
        card_copy['tags'] = [
            {'id': tag['id'], 'name': tag['name'], 'color': tag['color']}
            for tag in data['tags']
            if tag['id'] in card.get('tags', [])
        ]
        self.send_json(card_copy)

    def delete_card(self, card_id):
        """Delete a card."""
        global data
        if card_id in data['cards']:
            del data['cards'][card_id]
            save_data(data)
        self.send_json({'success': True})

    def reorder_cards(self, body):
        """Reorder cards after drag and drop."""
        global data
        for item in body:
            card_id = str(item['id'])
            if card_id in data['cards']:
                data['cards'][card_id]['column'] = item['column']
                data['cards'][card_id]['position'] = item['position']
        save_data(data)
        self.send_json({'success': True})

    def bulk_move_cards(self, body):
        """Move a card to a new position."""
        global data
        card_id = str(body.get('cardId'))
        new_column = body.get('column')
        new_position = body.get('position')
        
        if card_id not in data['cards']:
            self.send_json({'error': 'Card not found'}, 404)
            return
        
        card = data['cards'][card_id]
        old_column = card['column']
        old_position = card['position']
        
        # Shift cards in old column
        for c in data['cards'].values():
            if c['column'] == old_column and c['position'] > old_position:
                c['position'] -= 1
        
        # Make room in new column
        for c in data['cards'].values():
            if c['column'] == new_column and c['position'] >= new_position:
                c['position'] += 1
        
        # Move the card
        card['column'] = new_column
        card['position'] = new_position
        
        save_data(data)
        self.send_json({'success': True})

    # Checklist Methods
    def add_checklist_item(self, card_id, body):
        """Add a checklist item to a card."""
        global data
        card_id = str(card_id)
        if card_id not in data['cards']:
            self.send_json({'error': 'Card not found'}, 404)
            return
        
        card = data['cards'][card_id]
        checklist = card.get('checklist', [])
        max_pos = max((item['position'] for item in checklist), default=-1)
        
        new_item = {
            'id': int(card_id) * 1000 + len(checklist) + 1,
            'text': body.get('text', ''),
            'completed': body.get('completed', 0),
            'position': max_pos + 1
        }
        checklist.append(new_item)
        card['checklist'] = checklist
        save_data(data)
        self.send_json(new_item, 201)

    def update_checklist_item(self, item_id, body):
        """Update a checklist item."""
        global data
        item_id = int(item_id)
        for card in data['cards'].values():
            for item in card.get('checklist', []):
                if item['id'] == item_id:
                    if 'text' in body:
                        item['text'] = body['text']
                    if 'completed' in body:
                        item['completed'] = body['completed']
                    save_data(data)
                    self.send_json(item)
                    return
        self.send_json({'success': True})

    def delete_checklist_item(self, item_id):
        """Delete a checklist item."""
        global data
        item_id = int(item_id)
        for card in data['cards'].values():
            checklist = card.get('checklist', [])
            card['checklist'] = [item for item in checklist if item['id'] != item_id]
        save_data(data)
        self.send_json({'success': True})


def run(port=8080):
    """Start the server."""
    admin = is_admin()
    local_ips = get_local_ips()
    computer_name = get_computer_name()
    
    # Bind to all interfaces if admin, otherwise localhost only
    bind_address = '0.0.0.0' if admin else '127.0.0.1'
    server_address = (bind_address, port)
    httpd = HTTPServer(server_address, KanbanHandler)
    
    print('=' * 40)
    print('Kanban Board Server')
    print('=' * 40)
    print(f'Data file: {DATA_PATH}')
    print(f'Port: {port}')
    print()
    
    if admin:
        print('Running as Administrator - accessible over network')
        print(f'Local access:   http://127.0.0.1:{port}')
        if computer_name:
            print(f'Hostname:       http://{computer_name}:{port}')
        for ip in local_ips:
            print(f'Network access: http://{ip}:{port}')
    else:
        print(f'Local access:  http://127.0.0.1:{port}')
        print('(Run as Admin to enable network access)')
    
    print()
    print('Press Ctrl+C to stop')
    print('=' * 40)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down...')
        httpd.shutdown()


if __name__ == '__main__':
    run()