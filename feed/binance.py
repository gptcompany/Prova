import redis
from cryptofeed import FeedHandler
from cryptofeed.callback import TradeCallback, BookCallback
from cryptofeed.defines import BID, ASK,TRADES, L3_BOOK, L2_BOOK, TICKER, OPEN_INTEREST, FUNDING, LIQUIDATIONS, BALANCES, ORDER_INFO
from cryptofeed.exchanges import Binance
#from app.Custom_Coinbase import CustomCoinbase
from cryptofeed.backends.redis import BookRedis, BookStream, CandlesRedis, FundingRedis, OpenInterestRedis, TradeRedis, BookSnapshotRedisKey
from decimal import Decimal
import asyncio
import logging
import sys
from datetime import datetime, timezone
from redis import asyncio as aioredis
from Custom_Redis import CustomBookRedis, CustomTradeRedis
from statistics import mean
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
def main():
    logger.info('Starting binance feed')
    path_to_config = '/config_cf.yaml'
    fh = FeedHandler(config=path_to_config)  
    #symbols = fh.config.config['bf_symbols']
    symbols = ['BTC-USDT','ETH-BTC']
    fh.run(start_loop=False)
    print(fh.config.config['redis_host'])
    print(fh.config.config['redis_port'])
    fh.add_feed(Binance(
                # subscription={}, 
                # callbacks={},
                max_depth=100,
                subscription={
                    L2_BOOK: symbols, 
                    
                },
                callbacks={
                    L2_BOOK:   #book,
                        #BookCallback(book),
                        #BookCallback(
                            CustomBookRedis(
                            host=fh.config.config['redis_host'], 
                            port=fh.config.config['redis_port'], 
                            snapshots_only=False,
                            ssl=True,
                            decode_responses=True,
                            #score_key='timestamp',
                                            )
                            #         ),
                    

                },
                #cross_check=True,
                #timeout=-1
                )
                )
    fh.add_feed(Binance(
                    # subscription={}, 
                    # callbacks={},
                    
                    subscription={
                        
                        TRADES: symbols,
                    },
                    callbacks={
                        
                        TRADES: #trade, #[
                            #TradeCallback(trade),
                            #TradeCallback(
                                CustomTradeRedis(
                                host=fh.config.config['redis_host'], 
                                port=fh.config.config['redis_port'],
                                ssl=True,
                                decode_responses=True,
                                                    )
                                #       ),
                        #],
                    },
                    #cross_check=True,
                    #timeout=-1
                    )
                    )




    loop = asyncio.get_event_loop()
    # loop.create_task(check_last_update(
    #                                     redis_host=fh.config.config['redis_host'], 
    #                                     redis_port=fh.config.config['redis_port'], 
    #                                     threshold_seconds=0.1,
    #                                     check_interval=1,
    #                                     symbols=symbols,
    #                                     )
    #                 )
    # loop.create_task(calculate_mean_update_interval(
    #     redis_host=fh.config.config['redis_host'], 
    #     redis_port=fh.config.config['redis_port'], 
    #     use_ssl=True, 
    #     num_updates=3, 
    #     check_interval=1, 
    #     symbols=symbols,
    #     )
    #                 )
    loop.run_forever()

if __name__ == '__main__':
    main()

