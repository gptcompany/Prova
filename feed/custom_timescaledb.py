from collections import defaultdict
from datetime import datetime as dt
from typing import Tuple
import asyncpg
from yapic import json
from cryptofeed.backends.backend import BackendBookCallback, BackendCallback, BackendQueue
from cryptofeed.defines import CANDLES, FUNDING, OPEN_INTEREST, TICKER, TRADES, LIQUIDATIONS, INDEX
import logging
import sys
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
logger = logging.getLogger(__name__)
class TimeScaleCallback(BackendQueue):
    def __init__(self, host='127.0.0.1', user=None, pw=None, db=None, port=None, table=None, custom_columns: dict = None, none_to=None, numeric_type=float, **kwargs):
        """
        host: str
            Database host address
        user: str
            The name of the database role used for authentication.
        db: str
            The name of the database to connect to.
        pw: str
            Password to be used for authentication, if the server requires one.
        table: str
            Table name to insert into. Defaults to default_table that should be specified in child class
        custom_columns: dict
            A dictionary which maps Cryptofeed's data type fields to Postgres's table column names, e.g. {'symbol': 'instrument', 'price': 'price', 'amount': 'size'}
            Can be a subset of Cryptofeed's available fields (see the cdefs listed under each data type in types.pyx). Can be listed any order.
            Note: to store BOOK data in a JSONB column, include a 'data' field, e.g. {'symbol': 'symbol', 'data': 'json_data'}
        """
        self.conn = None
        self.table = table if table else self.default_table
        self.custom_columns = custom_columns
        self.numeric_type = numeric_type
        self.none_to = none_to
        self.user = user
        self.db = db
        self.pw = pw
        self.host = host
        self.port = port
        # Parse INSERT statement with user-specified column names
        # Performed at init to avoid repeated list joins
        self.insert_statement = f"INSERT INTO {self.table} ({','.join([v for v in self.custom_columns.values()])}) VALUES " if custom_columns else None
        self.running = True




    async def ensure_tables_exist(self):
        try:
            # Check if 'trades' table exists
            trades_exists = await self.conn.fetchval("SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename  = 'trades');")
            print(trades_exists)
            if not trades_exists:
                await self.conn.execute("""
                    CREATE TABLE trades (
                        exchange TEXT,
                        symbol TEXT,
                        data JSONB,
                        timestamp TIMESTAMPTZ,
                        receipt TIMESTAMPTZ,
                        id INT,
                        PRIMARY KEY (exchange, symbol, id)
                    );
                    SELECT create_hypertable('trades', 'timestamp');
                """)
                logging.info("Created 'trades' table")
                print('Created trades table')
                # side TEXT,
                # amount DOUBLE PRECISION,
                # price DOUBLE PRECISION,
                # type TEXT,

            # Check if 'book' table exists
            book_exists = await self.conn.fetchval("SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename  = 'book');")
            print(book_exists)
            if not book_exists:
                await self.conn.execute("""
                    CREATE TABLE book (
                        exchange TEXT,
                        symbol TEXT,
                        data JSONB,
                        timestamp TIMESTAMPTZ,
                        receipt TIMESTAMPTZ,
                        PRIMARY KEY (exchange, symbol, receipt)
                    );
                    SELECT create_hypertable('book', 'timestamp');
                """)
                logging.info("Created 'book' table")
                print("Created 'book' table")

            logging.info("Tables checked and created if necessary")

        except Exception as e:
            logging.error(f"Error while checking/creating tables: {str(e)}")

        finally:
            await self.conn.close()

    async def _connect(self):
        if self.conn is None:
            print('is connecting to timescaledb')
            self.conn = await asyncpg.connect(user=self.user, password=self.pw, database=self.db, host=self.host, port=self.port)
            print('check if tables exist')
            await self.ensure_tables_exist()

    def format(self, data: Tuple):
        feed = data[0]
        symbol = data[1]
        timestamp = data[2]
        receipt_timestamp = data[3]
        data = data[4]

        return f"(DEFAULT,'{timestamp}','{receipt_timestamp}','{feed}','{symbol}','{json.dumps(data)}')"
    def _custom_format_trades(self, data: Tuple):

            d = {
                **data[4],
                **{
                    'exchange': data[0],
                    'symbol': data[1],
                    'timestamp': data[2],
                    'receipt': data[3],
                    'id': data[4]['id']  # Assuming 'id' is part of the data structure in data[4]
                }
            }

            # Serialize the remaining trade details into JSON for the JSONB column
            trade_details = {k: v for k, v in data[4].items() if k != 'id'}
            d['data'] = json.dumps(trade_details)

            sequence_gen = (d[field] if field in d else 'NULL' for field in self.custom_columns.keys())
            sql_string = ','.join(str(s) if isinstance(s, float) or s == 'NULL' else "'" + str(s) + "'" for s in sequence_gen)
            return f"({sql_string})"
        
    def _custom_format(self, data: Tuple):

        d = {
            **data[4],
            **{
                'exchange': data[0],
                'symbol': data[1],
                'timestamp': data[2],
                'receipt': data[3],
            }
        }

        # Cross-ref data dict with user column names from custom_columns dict, inserting NULL if requested data point not present
        sequence_gen = (d[field] if d[field] else 'NULL' for field in self.custom_columns.keys())
        # Iterate through the generator and surround everything except floats and NULL in single quotes
        sql_string = ','.join(str(s) if isinstance(s, float) or s == 'NULL' else "'" + str(s) + "'" for s in sequence_gen)
        return f"({sql_string})"

    async def writer(self):
        while self.running:
            async with self.read_queue() as updates:
                if len(updates) > 0:
                    batch = []
                    for data in updates:
                        ts = dt.utcfromtimestamp(data['timestamp']) if data['timestamp'] else None
                        rts = dt.utcfromtimestamp(data['receipt_timestamp'])
                        batch.append((data['exchange'], data['symbol'], ts, rts, data))
                    await self.write_batch(batch)

    async def write_batch(self, updates: list):
        await self._connect()
        args_str = ','.join([self.format(u) for u in updates])

        async with self.conn.transaction():
            try:
                if self.custom_columns:
                    await self.conn.execute(self.insert_statement + args_str)
                else:
                    await self.conn.execute(f"INSERT INTO {self.table} VALUES {args_str}")

            except asyncpg.UniqueViolationError:
                # when restarting a subscription, some exchanges will re-publish a few messages
                pass


class TradesTimeScale(TimeScaleCallback, BackendCallback):
    default_table = TRADES
    try:
        def format(self, data: Tuple):
            if self.custom_columns:
                return self._custom_format_trades(data)
            else:
                exchange, symbol, timestamp, receipt, data = data
                id = f"'{data['id']}'" if data['id'] else 'NULL'
                otype = f"'{data['type']}'" if data['type'] else 'NULL'
                return f"(DEFAULT,'{timestamp}','{receipt}','{exchange}','{symbol}','{data['side']}',{data['amount']},{data['price']},{id},{otype})"
    except Exception as e:
            logging.error(f"Error in format method of BookTimeScale: {str(e)}")
            # Optionally, you can raise the exception again to propagate it
            #raise
class BookTimeScale(TimeScaleCallback, BackendBookCallback):
    default_table = 'book'

    def __init__(self, *args, snapshots_only=False, snapshot_interval=1000, **kwargs):
        self.snapshots_only = snapshots_only
        self.snapshot_interval = snapshot_interval
        self.snapshot_count = defaultdict(int)
        super().__init__(*args, **kwargs)

    def format(self, data: Tuple):
        try:
            if self.custom_columns:
                if 'book' in data[4]:
                    data[4]['data'] = json.dumps({'snapshot': data[4]['book']})
                else:
                    data[4]['data'] = json.dumps({'delta': data[4]['delta']})
                return self._custom_format(data)
            else:
                feed = data[0]
                symbol = data[1]
                timestamp = data[2]
                receipt_timestamp = data[3]
                data = data[4]
                if 'book' in data:
                    data = {'snapshot': data['book']}
                else:
                    data = {'delta': data['delta']}

                return f"(DEFAULT,'{timestamp}','{receipt_timestamp}','{feed}','{symbol}','{json.dumps(data)}')"

        except Exception as e:
            logging.error(f"Error in format method of BookTimeScale: {str(e)}")
            # Optionally, you can raise the exception again to propagate it
            #raise