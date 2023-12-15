import redis
import asyncio
from datetime import datetime, timezone

async def check_last_update(redis_host, redis_port, exchanges, symbols):
    """
    Continuously checks the timestamp of the last update in Redis for each exchange and symbol pair.

    Parameters:
    - redis_host (str): Host address for the Redis server.
    - redis_port (int): Port number for the Redis server.
    - exchanges (list): List of exchanges to check (e.g., ['bitfinex', 'binance']).
    - symbols (list): List of symbols to check (e.g., ['BTC-USDT', 'ETH-USDT']).
    """
    try:
        # Connect to Redis
        r = redis.Redis(host=redis_host, port=redis_port)

        while True:
            current_time = datetime.now(timezone.utc)
            print(f"Checking updates as of {current_time.isoformat()}")

            for exchange in exchanges:
                for symbol in symbols:
                    key_pattern = f"exchange:{exchange}:{symbol}:book"
                    
                    # Retrieve the latest entry's score (timestamp)
                    last_update_score = r.zrange(key_pattern, -1, -1, withscores=True)

                    if not last_update_score:
                        print(f"No data found for {exchange} {symbol}")
                        continue

                    # Extract the timestamp (score) of the last update
                    _, last_timestamp = last_update_score[0]
                    last_update_time = datetime.fromtimestamp(last_timestamp, tz=timezone.utc)

                    print(f"Last update for {exchange} {symbol}: {last_update_time.isoformat()}")

            await asyncio.sleep(3)  # Wait for 3 seconds before next check

    except Exception as e:
        print(f"Error occurred: {e}")

# Usage
# asyncio.run(check_last_update(redis_host, redis_port, ['bitfinex', 'binance'], ['BTC-USDT', 'ETH-USDT']))

if __name__ == "__main__":
    redis_host = "redis-0001-001.redis.tetmd7.apne1.cache.amazonaws.com"
    redis_port = "6379"
    exchanges = ['BITFINEX', 'BINANCE']
    symbols = ['BTC-USDT', 'ETH-USDT']
    asyncio.run(check_last_update(redis_host, redis_port, exchanges, symbols))