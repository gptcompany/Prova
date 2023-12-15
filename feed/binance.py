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
from Custom_Redis import CustomBookRedis
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
async def check_last_update(host, port, key_pattern, use_ssl=True, threshold_seconds=0.3, check_interval=1):
    """
    Continuously checks if the last update in Redis for a given key pattern is older than the specified threshold in seconds.
    """
    while True:
        try:
            url = f"rediss://{host}:{port}" if use_ssl else f"redis://{host}:{port}"
            r = await aioredis.from_url(url, decode_responses=True)
            print('Checking last update...')
            
            # Retrieve the latest entry's score (timestamp)
            last_update_score = r.zrange(key_pattern, -1, -1, withscores=True)

            if not last_update_score:
                print("No data found for the specified key pattern.")
            else:
                # Extract the timestamp (score) of the last update
                _, last_timestamp = last_update_score[0]
                last_update_time = datetime.fromtimestamp(last_timestamp, tz=timezone.utc)
                current_time = datetime.now(timezone.utc)
                time_diff = (current_time - last_update_time).total_seconds()

                if time_diff > threshold_seconds:
                    print(f"Last update is more than {threshold_seconds} seconds old. Last update was at {last_update_time.isoformat()}")
                else:
                    print('All ok! Last update:', last_update_time.isoformat())

        except Exception as e:
            logger.error(f"Error occurred: {e}")
        finally:
        # Close the connection
            await r.aclose()
        # Wait for a specified interval before checking again
        await asyncio.sleep(check_interval)
        
        
        

# Example usage of the function
# You need to replace '127.0.0.1', 6379, and 'your:key:pattern' with your actual Redis host, port, and key pattern.
# Example: check_last_update('127.0.0.1', 6379, 'exchange:symbol:book')
def main():
    print('main')
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
                    L2_BOOK:  [ #book,
                        BookCallback(book),
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
                    ],

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
                                TradeRedis(
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
    loop.create_task(check_last_update(
                                        redis_host=fh.config.config['redis_host'], 
                                        redis_port=fh.config.config['redis_port'], 
                                        key_pattern='BINANCE:BTC-USDT:book',
                                        threshold_seconds=0.3,
                                        check_interval=1,
                                        )
                    )
    loop.run_forever()

if __name__ == '__main__':
    main()