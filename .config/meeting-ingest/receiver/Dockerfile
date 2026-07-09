FROM python:3.12-alpine
RUN pip install --no-cache-dir paho-mqtt
COPY receiver.py /app/receiver.py
WORKDIR /app
EXPOSE 8080
USER nobody
CMD ["python", "receiver.py"]
