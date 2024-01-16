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
    
    async def set_retention_policy(self):
        try:
            # Set retention policy for table
            await self.conn.execute(f"""
                SELECT add_retention_policy('public.{self.table}', INTERVAL '7 days', if_not_exists => true);
            """)
            logging.info(f"Retention policy set for {self.table} table.")
        except Exception as e:
            logging.error(f"Error setting retention policies: {str(e)}")
            
    async def ensure_compression(self, segmentby_column, orderby_column, compress_interval='10 minutes'):
        try:
            # Check if compression is enabled
            segmentby_columns_formatted = ", ".join(segmentby_column)  # Format the column names properly
            orderby_column_formatted = ", ".join(orderby_column)
            await self.conn.execute("""
                ALTER TABLE {} SET (
                    timescaledb.compress, 
                    timescaledb.compress_segmentby = '{}', 
                    timescaledb.compress_orderby = '{}'
                );
            """.format(self.table, segmentby_columns_formatted, orderby_column_formatted))
            await self.conn.execute(f"""
                SELECT add_compression_policy('public.{self.table}', INTERVAL '{compress_interval}', if_not_exists => true);
            """)
            logging.info(f"Compression enabled for table {self.table}")
        except Exception as e:
            logging.error(f"Error while ensuring compression on table {self.table}: {str(e)}")


    async def ensure_tables_exist(self):
        try:
            # Check if 'trades' table exists
            table_exists = await self.conn.fetchval(f"SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename  = '{self.table}');")
            #print(table_exists)
            if not table_exists and self.table == 'trades':
                await self.conn.execute(f"""
                    CREATE TABLE {self.table} (
                        exchange TEXT,
                        symbol TEXT,
                        side TEXT,
                        amount DOUBLE PRECISION,
                        price DOUBLE PRECISION,
                        timestamp TIMESTAMPTZ,
                        receipt TIMESTAMPTZ,
                        id BIGINT,
                        PRIMARY KEY (exchange, symbol, timestamp, id)
                    );
                    SELECT create_hypertable('{self.table}', 'timestamp', chunk_time_interval => INTERVAL '10 minutes');
                """)
                logging.info(f"Created {self.table} hypertable")
                # side TEXT,
                # amount DOUBLE PRECISION,
                # price DOUBLE PRECISION,
                # type TEXT,
            
            elif not table_exists and self.table == 'book':
                await self.conn.execute(f"""
                    CREATE TABLE {self.table} (
                        exchange TEXT,
                        symbol TEXT,
                        data JSONB,
                        receipt TIMESTAMPTZ,
                        update_type TEXT,
                        PRIMARY KEY (exchange, symbol, receipt, update_type)
                    );
                    SELECT create_hypertable('{self.table}', 'receipt', chunk_time_interval => INTERVAL '10 minutes');
                """)
                logging.info(f"Created {self.table} hypertable")
            logging.info(f"Table {self.table} checked")
        except Exception as e:
            logging.error(f"Error while checking/creating tables: {str(e)}")

    async def _connect(self):
        if self.conn is None:
            logging.info('Connecting to TimescaleDB')
            try:
                self.conn = await asyncpg.connect(user=self.user, password=self.pw, database=self.db, host=self.host, port=self.port)
                await self.ensure_tables_exist()
                await self.ensure_compression(['exchange','symbol'], ['receipt', 'update_type'] if self.table == 'book' else ['timestamp', 'id'], compress_interval='10 minutes')
                await self.set_retention_policy()  # Setting retention policy
                
            except Exception as e:
                logging.error(f"Error while connecting to TimescaleDB: {str(e)}")


    def format(self, data: Tuple):
        feed = data[0]
        symbol = data[1]
        timestamp = data[2]
        receipt_timestamp = data[3]
        data = data[4]

        return f"(DEFAULT,'{timestamp}','{receipt_timestamp}','{feed}','{symbol}','{json.dumps(data)}')"
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
            try:
                async with self.read_queue() as updates:
                    if len(updates) > 0:
                        batch = []
                        for data in updates:
                            ts = dt.utcfromtimestamp(data['timestamp']) if data['timestamp'] else None
                            rts = dt.utcfromtimestamp(data['receipt_timestamp'])
                            batch.append((data['exchange'], data['symbol'], ts, rts, data))
                        await self.write_batch(batch)
            except Exception as e:
                logging.error(f"Error in writer method in TimeScaleCallback: {str(e)}")
                self.conn = None # reset connection
                await self._connect()  # Attempt to reconnect


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
                
                return self._custom_format(data)
            else:
                exchange, symbol, timestamp, receipt, data = data
                id = f"'{data['id']}'" if data['id'] else 'NULL'
                otype = f"'{data['type']}'" if data['type'] else 'NULL'
                return f"(DEFAULT,'{timestamp}','{receipt}','{exchange}','{symbol}','{data['side']}',{data['amount']},{data['price']},{id},{otype})"
    except Exception as e:
            logging.error(f"Error in format method of TradesTimeScale: {str(e)}")
            # Optionally, you can raise the exception again to propagate it
            #raise
class BookTimeScale(TimeScaleCallback, BackendBookCallback):
    default_table = 'book'

    def __init__(self, *args, snapshots_only=False, snapshot_interval=10000, **kwargs):
        self.snapshots_only = snapshots_only
        self.snapshot_interval = snapshot_interval
        self.snapshot_count = defaultdict(int)
        super().__init__(*args, **kwargs)

    def format(self, data: Tuple):
        try:
            if self.custom_columns:
                if 'book' in data[4]:
                    data[4]['data'] = json.dumps(data[4]['book'])
                    data[4]['update_type'] = 'snapshot' 
                else:
                    data[4]['data'] = json.dumps(data[4]['delta'])
                    data[4]['update_type'] = 'delta'
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