import redis
import asyncio
from datetime import datetime, timezone
def test_redis_connection(host, port, use_ssl):
    try:
        url = f"rediss://{host}:{port}" if use_ssl else f"redis://{host}:{port}"
        r = redis.Redis.from_url(url, ssl=use_ssl, decode_responses=True)
        
        # Test set and get
        r.set("test_key", "test_value")
        value = r.get("test_key")
        print(f"Retrieved value: {value}")

    except Exception as e:
        print(f"Error connecting to Redis: {e}")

# Replace with your ElastiCache Redis endpoint and port
test_redis_connection('your-elasticache-endpoint', 6379, True)
def add_and_check_key(redis_host, redis_port, key, value):
    """
    Adds a key and value to Redis and checks if the value persists.

    Parameters:
    - redis_host (str): The hostname of the Redis server.
    - redis_port (int): The port number of the Redis server.
    - key (str): The key to add to Redis.
    - value (str): The value to associate with the key.
    """
    try:
        # Connect to Redis
        r = redis.Redis(host=redis_host, port=redis_port, ssl=ssl_enabled, decode_responses=True)

        # Add key-value pair
        r.set(key, value)

        # Retrieve the value to check if it persisted
        retrieved_value = r.get(key)

        # Check if the retrieved value matches the original value
        if retrieved_value == value:
            print(f"Success: The value for '{key}' is persisted as '{retrieved_value}'")
        else:
            print(f"Failed: The value for '{key}' did not persist or is incorrect.")

    except Exception as e:
        print(f"Error occurred: {e}")
def is_redis_connected(redis_client):
    """
    Check if the Redis server is connected.
    """
    try:
        print('trying to pint...')
        response = redis_client.ping()
        print(f"Redis Ping Response: {response}")
        return True
    except Exception as e:
        print(f"Redis connection error: {e}")
        return False
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
        r = redis.Redis(host=redis_host, port=redis_port, ssl=ssl_enabled, decode_responses=True)

        while True:
            current_time = datetime.now(timezone.utc)
            print(f"Checking updates as of {current_time.isoformat()}")

            for exchange in exchanges:
                for symbol in symbols:
                    key_pattern = f"{exchange}:{symbol}:book"
                    print('before retrieve the entry in redis...')
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
    redis_port = 6379
    ssl_enabled = True
    exchanges = ['BITFINEX', 'BINANCE']
    symbols = ['BTC-USDT', 'ETH-USDT']
    
    add_and_check_key(redis_host, redis_port, 'test_key', 'test_value')
    
    print('Create Redis client')
    r = redis.Redis(host=redis_host, port=redis_port, decode_responses=True, ssl=ssl_enabled)

    print('Check if Redis is connected')
    if is_redis_connected(r):
        asyncio.run(check_last_update(redis_host, redis_port, exchanges, symbols))
    else:
        print("Failed to connect to Redis. Please check your connection settings.")
    print('test with the method from cryptofeed:')    
    test_redis_connection(redis_host, redis_port, ssl=True)