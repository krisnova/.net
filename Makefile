# =========================================================================== #
#              Copyright (c) 2022 Kris Nóva <krisnova@krisnova.net>           #
#                                                                             #
#                 +-----------------------------------------+                 #
#                 |   ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗   |                 #
#                 |   ████╗  ██║██╔═████╗██║   ██║██╔══██╗  |                 #
#                 |   ██╔██╗ ██║██║██╔██║██║   ██║███████║  |                 #
#                 |   ██║╚██╗██║████╔╝██║╚██╗ ██╔╝██╔══██║  |                 #
#                 |   ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║  |                 #
#                 |   ╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝  |                 #
#                 +-----------------------------------------+                 #
#                                                                             #
#                                                                             #
# =========================================================================== #

default: help

hugo: ## Build /public directory
	npm install postcss-cli
	hugo --minify

submodule: ## Build the git submodule
	git submodule update --init --recursive

dev: submodule ## Run the local server
	hugo serve . --bind=0.0.0.0

.PHONY: help
help:  ## 🤔 Show help messages for make targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[32m%-30s\033[0m %s\n", $$1, $$2}'
