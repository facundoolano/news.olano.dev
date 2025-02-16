.PHONY: run deploy build templates

run:
	gleam run

watch:
	watchexec --restart --verbose --wrap-process=session --stop-signal SIGTERM --exts gleam --debounce 500ms --watch src/ -- "gleam run"

deploy:
	rsync -avz --progress build/erlang-shipment $(SSH):/home/$(USER)/gleam_news/ && \
	ssh $(SSH) "chown -R $(USER):$(USER) /home/$(USER)/gleam_news/ && sudo systemctl restart news"

build:
	gleam export erlang-shipment && rm -rf rm build/erlang-shipment/news/priv/feedcache/

templates:
	matcha && gleam format src
