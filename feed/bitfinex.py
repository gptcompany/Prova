from redis import Redis
from cryptofeed import FeedHandler
from cryptofeed.callback import TradeCallback, BookCallback
from cryptofeed.defines import BID, ASK,TRADES, L3_BOOK, L2_BOOK, TICKER, OPEN_INTEREST, FUNDING, LIQUIDATIONS, BALANCES, ORDER_INFO
from cryptofeed.exchanges import BITFINEX, Bitfinex
#from app.Custom_Coinbase import CustomCoinbase
from cryptofeed.backends.redis import BookRedis, BookStream, CandlesRedis, FundingRedis, OpenInterestRedis, TradeRedis, BookSnapshotRedisKey
from decimal import Decimal
import asyncio
import logging
from datetime import datetime
import sys
from Custom_Redis import CustomBookRedis, CustomTradeRedis
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
logger = logging.getLogger(__name__)
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
    #await asyncio.sleep(0.2)

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
async def aio_task():
    while True:
        print("Other task running")
        await asyncio.sleep(10)       
def main():
    logger.info('Starting bitfinex feed')
    path_to_config = '/config_cf.yaml'
    try:
        fh = FeedHandler(config=path_to_config)  
        symbols = fh.config.config['bf_symbols']
        fh.run(start_loop=False)
        fh.add_feed(BITFINEX,
                        max_depth=50,
                        subscription={
                            L2_BOOK: symbols, 
                        },
                        callbacks={
                            L2_BOOK:
                                    CustomBookRedis(
                                    host=fh.config.config['redis_host'], 
                                    port=fh.config.config['redis_port'], 
                                    snapshots_only=False,
                                    ssl=True,
                                    decode_responses=True,
                                    #score_key='timestamp',
                                                    )
                        },
                        cross_check=True,
                        )
                        
        fh.add_feed(Bitfinex(
                        subscription={
                            TRADES: symbols,
                        },
                        callbacks={
                            TRADES: 
                                    CustomTradeRedis(
                                    host=fh.config.config['redis_host'], 
                                    port=fh.config.config['redis_port'],
                                    ssl=True,
                                    decode_responses=True,
                                                        )
                        },
                        cross_check=True,
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