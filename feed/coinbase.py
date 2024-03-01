
from redis import Redis
from cryptofeed import FeedHandler
from cryptofeed.backends.aggregate import Throttle
from cryptofeed.callback import TradeCallback, BookCallback
from cryptofeed.defines import BID, ASK,TRADES, L3_BOOK, L2_BOOK, TICKER, OPEN_INTEREST, FUNDING, LIQUIDATIONS, BALANCES, ORDER_INFO, COINBASE
from cryptofeed.exchanges import Coinbase
#from app.Custom_Coinbase import CustomCoinbase
from cryptofeed.backends.redis import BookRedis, BookStream, CandlesRedis, FundingRedis, OpenInterestRedis, TradeRedis, BookSnapshotRedisKey
from decimal import Decimal
import asyncio
import logging
from custom_coinbase import CustomCoinbase
import sys
import os
logging.basicConfig(stream=sys.stdout, level=logging.INFO, format='%(asctime)s:%(levelname)s:%(message)s')
logger = logging.getLogger(__name__)
async def trade(t, receipt_timestamp):
    assert isinstance(t.timestamp, float)
    assert isinstance(t.side, str)
    assert isinstance(t.amount, Decimal)
    assert isinstance(t.price, Decimal)
    assert isinstance(t.exchange, str)
    print(f"Trade received at {receipt_timestamp}: {t}")
    #await asyncio.sleep(0.15)

async def book(book, receipt_timestamp):
    print(f'Book received at {receipt_timestamp} for {book.exchange} - {book.symbol}, with {len(book.book)} entries. Top of book prices: {book.book.asks.index(0)[0]} - {book.book.bids.index(0)[0]}')
    if book.delta:
        print(f"Delta from last book contains {len(book.delta[BID]) + len(book.delta[ASK])} entries.")
    if book.sequence_number:
        assert isinstance(book.sequence_number, int)
    #await asyncio.sleep(0.2)
async def aio_task():
    while True:
        print("Other task running")
        await asyncio.sleep(1)
def main():
    
    # Safely get the home directory, with a fallback if HOME is not set
    home_directory = os.environ.get('HOME', '')
    if not home_directory:
        logger.error('The HOME environment variable is not set.')
    path_to_config = os.path.join(home_directory, 'config_cf.yaml')
    #logger.info(f'Using config at {path_to_config}')
    fh = FeedHandler(config=path_to_config)
    #symbols = fh.config.config['cb_symbols']
    symbols = ['BTC-USDT','ETH-BTC']
    fh.run(start_loop=False)
    
    fh.add_feed(Coinbase(
                    config=path_to_config,
                    subscription={
                    
                    TRADES: symbols,
                    },
                    callbacks={
                        TRADES: trade,
                            #[
                            #TradeCallback(trade),
                        #TradeCallback(
                                #TradeRedis(
                                #host=fh.config.config['redis_host'], 
                                #port=fh.config.config['redis_port'],
                                #                    )
                            #           ),
                        #],
                        },
                    #cross_check=True,
                    #timeout=-1
                    )
        )
    fh.add_feed(CustomCoinbase(
                        max_depth=100,
                        config=path_to_config,
                        subscription={
                        L3_BOOK: symbols, 
                        
                        },
                        callbacks={
                            L3_BOOK: book,
                                #[
                                #BookCallback(book),
                                
                            #BookCallback(
                                    #BookRedis(
                                    #host=fh.config.config['redis_host'], 
                                    #port=fh.config.config['redis_port'], 
                                    #snapshots_only=False,
                                    #score_key='timestamp'
                                    #                    )
                                #           ),
                            #],
                            },
                        #cross_check=True,
                        #timeout=-1
                        )
            )
        
    loop = asyncio.get_event_loop()
    loop.create_task(aio_task())
    loop.run_forever()


if __name__ == '__main__':
    main()