# LC_Coop — relay de coordinación (contenedor)
FROM python:3.12-slim

WORKDIR /app
COPY relay_server.py .

# Puerto UDP del relay (configurable con -e PORT=...)
ENV PORT=27020
EXPOSE 27020/udp

# Sin dependencias externas (solo stdlib)
CMD ["sh", "-c", "python3 relay_server.py ${PORT}"]
