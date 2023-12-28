import redis
import asyncio
from datetime import datetime, timezone
from redis import asyncio as aioredis
async def test_redis_connection(host, port, use_ssl):
    try: 
        while True: 
        
            url = f"rediss://{host}:{port}" if use_ssl else f"redis://{host}:{port}"
            r = await aioredis.from_url(url, decode_responses=True)
            
            # Test set and get
            await r.set("test_key", "test_value")
            value = await r.get("test_key")
            print(f"Retrieved value: {value}")
            
            await asyncio.sleep(3)

    except Exception as e:
        print(f"Error connecting to Redis: {e}")
    
    finally:
        # Close the connection
        await r.aclose()

# Replace with your ElastiCache Redis endpoint and port
async def add_and_check_key(redis_host, redis_port, key, value, use_ssl=True):
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
        url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
        r = await aioredis.from_url(url, decode_responses=True)

        # Add key-value pair
        r.set(key, value)

        # Retrieve the value to check if it persisted
        retrieved_value = await r.get(key)

        # Check if the retrieved value matches the original value
        if retrieved_value == value:
            print(f"Success: The value for '{key}' is persisted as '{retrieved_value}'")
        else:
            print(f"Failed: The value for '{key}' did not persist or is incorrect.")

    except Exception as e:
        print(f"Error occurred: {e}")
async def is_redis_connected(redis_client):
    """
    Check if the Redis server is connected.
    """
    try:
        print('trying to pint...')
        response = await redis_client.ping()
        print(f"Redis Ping Response: {response}")
        return True
    except Exception as e:
        print(f"Redis connection error: {e}")
        return False
async def check_last_update(redis_host, redis_port, exchanges, symbols, use_ssl):
    """
    Continuously checks the timestamp of the last update in Redis for each exchange and symbol pair.

    Parameters:
    - redis_host (str): Host address for the Redis server.
    - redis_port (int): Port number for the Redis server.
    - exchanges (list): List of exchanges to check (e.g., ['bitfinex', 'binance']).
    - symbols (list): List of symbols to check (e.g., ['BTC-USDT', 'ETH-USDT']).
    """
    print('checklast upadate function')
    try:
        # Connect to Redis
        url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
        r = await aioredis.from_url(url, decode_responses=True)

        while True:
            current_time = datetime.now(timezone.utc)
            print(f"Checking updates as of {current_time.isoformat()}")

            for exchange in exchanges:
                for symbol in symbols:
                    key_pattern = f"trades-{exchange}-{symbol}"
                    #print('before retrieve the entry in redis...')
                    # Retrieve the latest entry's score (timestamp)
                    last_update_score = await r.zrange(key_pattern, -1, -1, withscores=True)

                    if not last_update_score:
                        print(f"No data found for {key_pattern}")
                        continue

                    # Extract the timestamp (score) of the last update
                    _, last_timestamp = last_update_score[0]
                    last_update_time = datetime.fromtimestamp(last_timestamp, tz=timezone.utc)

                    print(f"Last update for {exchange} {symbol}: {last_update_time.isoformat()}")

            await asyncio.sleep(3)  # Wait for 3 seconds before next check

    except Exception as e:
        print(f"Error occurred: {e}")


async def subscribe_to_channels(redis_host, redis_port, exchanges, symbols, use_ssl):
    try:
        url = f"rediss://{redis_host}:{redis_port}" if use_ssl else f"redis://{redis_host}:{redis_port}"
        conn = await aioredis.create_redis_pool(url, decode_responses=True)

        # Create a list of channel names based on exchanges, symbols, and data types (e.g., 'book' and 'trades')
        channels = []
        for exchange in exchanges:
            for symbol in symbols:
                for data_type in ['book', 'trades']:
                    channel_name = f"{data_type}-{exchange}-{symbol}"
                    channels.append(channel_name)

        # Subscribe to all channels
        res = await conn.pubsub(*channels)

        # Create a task to handle incoming messages for each channel
        tasks = []
        for channel in res:
            task = asyncio.create_task(handle_channel_messages(channel))
            tasks.append(task)

        # Wait for all tasks to complete
        await asyncio.gather(*tasks)

    except Exception as e:
        print(f"Error subscribing to channels: {e}")
    try:
        await conn.aclose()
    except AttributeError as e:
        print(f"Attribute Error closing connection: {e}")


async def handle_channel_messages(channel):
    while await channel.wait_message():
        message = await channel.get(encoding='utf-8')
        print(f"Received message on channel {channel.name}: {message}")

async def main():
    redis_host = "redis-0001-001.redis.tetmd7.apne1.cache.amazonaws.com"
    redis_port = 6379
    ssl_enabled = True
    exchanges = ['BITFINEX', 'BINANCE']
    symbols = ['BTC-USDT', 'ETH-USDT']
    r = None
    try:
    # Assuming add_and_check_key is synchronous
        #await add_and_check_key(redis_host, redis_port, 'test_key', 'test_value', use_ssl=ssl_enabled)
        #await test_redis_connection(host=redis_host, port=redis_port, use_ssl=ssl_enabled)
        print('Create Redis client')
        tasks = [
            check_last_update(redis_host, redis_port, exchanges, symbols, use_ssl=ssl_enabled),
            subscribe_to_channels(redis_host, redis_port, exchanges, symbols, use_ssl=ssl_enabled)
        ]
        await asyncio.gather(*tasks)
    except Exception as e:
        print(f"An error occurred: {e}")
    finally:
        if r:
            await r.aclose()
        
if __name__ == "__main__":
    asyncio.run(main())
    #version2
