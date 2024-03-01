import redis
from cryptofeed import FeedHandler
from cryptofeed.callback import TradeCallback, BookCallback
from cryptofeed.defines import BID, ASK,TRADES, L3_BOOK, L2_BOOK, TICKER, OPEN_INTEREST, FUNDING, LIQUIDATIONS, BALANCES, ORDER_INFO
from cryptofeed.exchanges import Bitstamp
from cryptofeed.backends.redis import BookRedis, BookStream, CandlesRedis, FundingRedis, OpenInterestRedis, TradeRedis, BookSnapshotRedisKey
from decimal import Decimal
import asyncio
import logging
import sys
from datetime import datetime, timezone
from redis import asyncio as aioredis
from Custom_Redis import CustomBookRedis, CustomTradeRedis, CustomBookStream
from custom_timescaledb import BookTimeScale, TradesTimeScale
from statistics import mean
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
logger = logging.getLogger(__name__)
async def funding(f, receipt_timestamp):
    print(f"Funding update received at {receipt_timestamp}: {f}")
async def liquidations(liquidation, receipt_timestamp):
    print(f"Liquidation received at {receipt_timestamp}: {liquidation}")
async def oi(update, receipt_timestamp):
    print(f"Open Interest update received at {receipt_timestamp}: {update}")
async def trade(t, receipt_timestamp):
    assert isinstance(t.timestamp, float)
    assert isinstance(t.side, str)
    assert isinstance(t.amount, Decimal)
    assert isinstance(t.price, Decimal)
    assert isinstance(t.exchange, str)
    date_time = datetime.utcfromtimestamp(receipt_timestamp)
    # Extract milliseconds
    milliseconds = int((receipt_timestamp - int(receipt_timestamp)) * 1000)
    # Format the datetime object as a string and manually add milliseconds
    formatted_date = date_time.strftime('%Y-%m-%d %H:%M:%S.') + f'{milliseconds:03d}'
    print(f"Trade received at {formatted_date}: {t}")
    await asyncio.sleep(0.5)

async def book(book, receipt_timestamp):
    date_time = datetime.utcfromtimestamp(receipt_timestamp)
    # Extract milliseconds
    milliseconds = int((receipt_timestamp - int(receipt_timestamp)) * 1000)
    # Format the datetime object as a string and manually add milliseconds
    formatted_date = date_time.strftime('%Y-%m-%d %H:%M:%S.') + f'{milliseconds:03d}'
    print(f"Book received at {formatted_date} for {book.exchange} - {book.symbol}, with {len(book.book)} entries. Top of book prices: {book.book.asks.index(0)[0]} - {book.book.bids.index(0)[0]}")
    if book.delta:
        print(f"Delta from last book contains {len(book.delta[BID]) + len(book.delta[ASK])} entries.")
    if book.sequence_number:
        assert isinstance(book.sequence_number, int)
    await asyncio.sleep(0.5) 
custom_columns = {
    'exchange': 'exchange',     # Maps Cryptofeed's 'exchange' field to the 'exchange' column in TimescaleDB
    'symbol': 'symbol',         # Maps Cryptofeed's 'symbol' field to the 'symbol' column in TimescaleDB
    #'timestamp': 'timestamp',   # Maps Cryptofeed's 'timestamp' field to the 'timestamp' column in TimescaleDB
    'receipt': 'receipt',       # Maps Cryptofeed's 'receipt' field to the 'receipt' column in TimescaleDB
    'data': 'data',              # Maps the serialized JSON data to the 'data' JSONB column in TimescaleDB
    'update_type': 'update_type',     
    
}
custom_columns_trades= {
    'exchange': 'exchange',     # Maps Cryptofeed's 'exchange' field to the 'exchange' column in TimescaleDB
    'symbol': 'symbol',         # Maps Cryptofeed's 'symbol' field to the 'symbol' column in TimescaleDB
    'timestamp': 'timestamp',   # Maps Cryptofeed's 'timestamp' field to the 'timestamp' column in TimescaleDB
    'receipt': 'receipt',
    'side': 'side',              
    'amount': 'amount',
    'price': 'price',            
    'id': 'id',                  # Maps Cryptofeed's 'id' field to the 'id' column in TimescaleDB
}
def main():
    logger.info('Starting binance feed')
    path_to_config = '/config_cf.yaml'
    snapshot_interval = 10000
    ttl=3600
    try:
        fh = FeedHandler(config=path_to_config)
        postgres_cfg = {
            'host': fh.config.config['pg_host'], 
            'user': 'postgres', 
            'db': 'db0', 
            'pw': fh.config.config['timescaledb_password'], 
            'port': '5432',
                        }
        print("still loading")
        symbols = fh.config.config['bn_symbols']
        pairs = Bitstamp.symbols()[:]
        print(pairs)
        
        symbols_fut = ['BTC-USD','ETH-USD']
        #function to check if symbols are in the pairs list:
        [print(f"{symbol} is {'in' if symbol in pairs else 'not in'} pairs list") for symbol in symbols_fut]
        fh.run(start_loop=False)

        print("ok loaded")
        # fh.add_feed(Binance(
        #             max_depth=50,
        #             subscription={
        #                 L2_BOOK: symbols,   
        #             },
        #             callbacks={
        #                     L2_BOOK:[
        #                             CustomBookStream(
        #                             #host=fh.config.config['redis_host'],
        #                             host 
        #                             port=fh.config.config['redis_port'], 
        #                             snapshots_only=False,
        #                             ssl=True,
        #                             decode_responses=True,
        #                             snapshot_interval=snapshot_interval,
        #                             ttl=ttl,
        #                             #score_key='timestamp',
        #                                 ),
        #                             BookTimeScale(
        #                                 snapshots_only=False,
        #                                 snapshot_interval=snapshot_interval,
        #                                 #table='book',
        #                                 custom_columns=custom_columns, 
        #                                 **postgres_cfg
        #                                 )
        #                     ]
        #                 },
        #                 cross_check=True,
        #                 )
        #                 )
        # fh.add_feed(Binance(
        #                 subscription={
        #                     TRADES: symbols,
        #                 },
        #                 callbacks={
        #                     TRADES:[ 
        #                             CustomTradeRedis(
        #                             host=fh.config.config['redis_host'], 
        #                             port=fh.config.config['redis_port'],
        #                             score_key='timestamp',
        #                             ssl=True,
        #                             decode_responses=True,
        #                             ttl=ttl,
        #                                 ),
        #                             TradesTimeScale(
        #                                 custom_columns=custom_columns_trades,
        #                                 #table='trades',
        #                                 **postgres_cfg
        #                                 )
                                    
        #                     ]
        #                 },
        #                 #cross_check=True,
        #                 #timeout=-1
        #                 )
        #                 )
        fh.add_feed(Bitstamp(timeout=5000,
                           max_depth=50,
                        subscription={
                            L3_BOOK: symbols_fut, 
                            TRADES: symbols_fut,
                            #FUNDING: symbols_fut,   ##############not supported on Bitstamp
                            #OPEN_INTEREST: symbols_fut,
                            #LIQUIDATIONS: symbols_fut,
                        },
                        callbacks={
                            L3_BOOK:[book], 
                            TRADES:[trade],
                            #FUNDING:[funding],
                            #OPEN_INTEREST:[oi],
                            #LIQUIDATIONS:[liquidations],
                        },
                        #cross_check=True,
                        #timeout=-1
                        )
                        )
        loop = asyncio.get_event_loop()
        # loop.create_task()
        loop.run_forever()
        
    except Exception as e:
        logger.error(f"An error occurred: {e}")
        # Optionally, you can re-raise the exception if you want the program to stop in case of errors
        # raise

if __name__ == '__main__':
    main()

