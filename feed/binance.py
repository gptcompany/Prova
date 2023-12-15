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
async def check_last_update(redis_host, redis_port, key_pattern, threshold_seconds=0.1):
    
    """
    Check if the last update in Redis for a given key pattern is older than the specified threshold in seconds.
    Logs a warning if the last update is more than threshold_seconds old.

    Parameters:
    - redis_host (str): Host address for the Redis server.
    - redis_port (int): Port number for the Redis server.
    - key_pattern (str): Pattern of the keys to check (e.g., 'exchange:symbol:book').
    - threshold_seconds (int): Threshold in seconds to determine if the update is recent.

    Returns:
    - bool: True if the last update is within the threshold, False otherwise.
    - str: The timestamp of the last update or an error message.
    """
    try:
        # Connect to Redis
        r = redis.Redis(host=redis_host, port=redis_port, ssl=True, decode_responses=True)

        # Assuming the most recent data is stored in a sorted set with timestamps as scores
        # Retrieve the latest entry's score (timestamp)
        last_update_score = r.zrange(key_pattern, -1, -1, withscores=True)

        if not last_update_score:
            return False, "No data found for the specified key pattern."

        # Extract the timestamp (score) of the last update
        _, last_timestamp = last_update_score[0]

        # Convert timestamp to a datetime object
        last_update_time = datetime.fromtimestamp(last_timestamp, tz=timezone.utc)

        # Current time
        current_time = datetime.now(timezone.utc)

        # Calculate time difference in seconds
        time_diff = (current_time - last_update_time).total_seconds()

        # Check if the time difference is greater than the threshold
        if time_diff > threshold_seconds:
            logger.warning(f"Last update is more than {threshold_seconds} seconds old. Last update was at {last_update_time.isoformat()}")
            return False, last_update_time.isoformat()

        return True, last_update_time.isoformat()

    except Exception as e:
        logger.error(f"Error occurred: {e}")
        return False, f"Error occurred: {e}"

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
    fh.add_feed(Binance(
                # subscription={}, 
                # callbacks={},
                max_depth=100,
                subscription={
                    L2_BOOK: symbols, 
                    
                },
                callbacks={
                    L2_BOOK: #book, # [
                        #BookCallback(book),
                        #BookCallback(
                            BookRedis(
                            host=fh.config.config['redis_host'], 
                            port=fh.config.config['redis_port'], 
                            snapshots_only=False,
                            ssl=True,
                            #score_key='timestamp',
                                            )
                            #         ),
                    #],

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
                                        key_pattern='exchange:symbol:book'
                                        )
                    )
    loop.run_forever()


if __name__ == '__main__':
    main()