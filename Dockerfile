# Use an official Python runtime as a parent image
FROM python:3.10
ARG GTB_ACCESS_TOKEN
# Set them as environment variables if needed in the running container
ENV GTB_ACCESS_TOKEN=${GTB_ACCESS_TOKEN}
ARG AWS_REGION
ENV AWS_REGION=${AWS_REGION}
ARG AMAZON_ACCESS_KEY
ENV AMAZON_ACCESS_KEY=${AMAZON_ACCESS_KEY}
ARG AMAZON_SECRET_ACCESS_KEY
ENV AMAZON_SECRET_ACCESS_KEY=${AMAZON_SECRET_ACCESS_KEY}
RUN pip install poetry==1.6.1
RUN poetry config virtualenvs.create false
WORKDIR /code
COPY ./pyproject.toml ./poetry.lock* ./
COPY ./README.md /code/
COPY ./feed ./feed
RUN poetry install  --no-interaction --no-ansi --no-root
RUN apt-get update
# Copy the Supervisor configuration file
#COPY ./supervisord.conf /etc/supervisor/conf.d/supervisord.conf


#EXPOSE 8000
#EXPOSE 9001


# Start Supervisor to manage your processes
#CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
CMD ["python", "-m", "nbbo"]

