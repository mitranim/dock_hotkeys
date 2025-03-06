MAKEFLAGS := --silent --always-build
VERB := $(and $(filter true,$(verb)),-v)
SWIFT_FLAGS := -c release
HOME_LOG_DIR := $(HOME)/.local/share/dock_hotkeys
HOME_BIN_DIR := $(HOME)/.local/bin
HOME_BIN_PATH := $(HOME_BIN_DIR)/dock_hotkeys
LAUNCH_AGENT_DIR := $(HOME)/Library/LaunchAgents
LAUNCH_AGENT_PATH := $(LAUNCH_AGENT_DIR)/com.mitranim.dock_hotkeys.plist

run: build
	swift run $(SWIFT_FLAGS) dock_hotkeys $(VERB)

build:
	swift build $(SWIFT_FLAGS)

clean:
	swift package clean

install: build
	mkdir -p $(HOME_BIN_DIR)
	cp .build/release/dock_hotkeys "$(HOME_BIN_PATH)"
	echo "Copied dock_hotkeys to $(HOME_BIN_DIR)."
	echo "Make sure $(HOME_BIN_DIR) is in your PATH."

uninstall: agent.uninstall bin.uninstall

bin.uninstall:
	rm "$(HOME_BIN_PATH)" && echo "Removed dock_hotkeys from $(HOME_BIN_DIR)." || echo "dock_hotkeys not installed."

agent: install
	mkdir -p "$(HOME_LOG_DIR)"
	mkdir -p "$(LAUNCH_AGENT_DIR)"
	$(MAKE) agent.uninstall
	# Rewrite the plist to provide absolute file paths.
	# Seems to be required. `launchctl` fails to run the agent otherwise.
	cat com.mitranim.dock_hotkeys.plist | \
		sed \
			-e "s|HOME_BIN_PATH|$(HOME_BIN_PATH)|g" \
			-e "s|HOME_LOG_DIR|$(HOME_LOG_DIR)|g" \
			-e "s|VERB|$(VERB)|g" \
		>> "$(LAUNCH_AGENT_PATH)"
	echo "Copied the launch agent plist to $(LAUNCH_AGENT_PATH)."
	chmod 644 "$(LAUNCH_AGENT_PATH)"
	echo "The agent will load automatically on next login."
	echo "Attempting to load..."
	launchctl load -w "$(LAUNCH_AGENT_PATH)"
	echo "Waiting for agent to start..."
	sleep 0.1
	echo "Checking agent status..."
	# Better check if agent is running.
	if pgrep -f dock_hotkeys > /dev/null; then \
		echo "✅ Agent is running. To view logs, run: 'make agent.status'."; \
	else \
		echo "❌ Agent failed to start. Check logs with: 'make agent.status'."; \
		echo "Attempting to start agent manually..."; \
		launchctl start com.mitranim.dock_hotkeys; \
		sleep 0.1; \
		if pgrep -f dock_hotkeys > /dev/null; then \
			echo "✅ Agent started successfully after manual intervention."; \
		else \
			echo "❌ Agent still failed to start. Check the logs for errors."; \
		fi; \
	fi
	echo "To unload the agent and delete the plist file, run: 'make agent.drop'."
	echo "Alternatively, unload the agent and delete the plist file manually,"
	echo "or disable it in System Settings → Login Items and Extensions."

agent.uninstall:
	$(MAKE) agent.stop
	-pkill -f dock_hotkeys && echo "Agent process killed." || echo "Agent process not running."
	rm "$(LAUNCH_AGENT_PATH)" && echo "Agent plist file removed." || echo "Agent plist file not installed."
	rm -rf "$(HOME_LOG_DIR)" && echo "Agent log directory removed (or not present)." || echo "Agent log directory not present."

agent.stop:
	-launchctl unload -w "$(LAUNCH_AGENT_PATH)" || true && echo "Agent unloaded (or not loaded)."

agent.restart:
	$(MAKE) agent.stop
	echo "Attempting to load and start agent..."
	launchctl load -w "$(LAUNCH_AGENT_PATH)"
	echo "Waiting for agent to start..."
	sleep 0.1
	if pgrep -f dock_hotkeys > /dev/null; then \
		echo "✅ Agent restarted successfully."; \
	else \
		echo "⚠️ Agent loaded but process not detected. Starting manually..."; \
		launchctl start com.mitranim.dock_hotkeys; \
		sleep 0.1; \
		if pgrep -f dock_hotkeys > /dev/null; then \
			echo "✅ Agent started successfully after manual intervention."; \
		else \
			echo "❌ Agent failed to start. Check logs with: 'make agent.status'."; \
		fi; \
	fi

agent.status:
	if launchctl list | grep com.mitranim.dock_hotkeys > /dev/null; then \
		echo "✅ Agent is loaded in launchctl."; \
	else \
		echo "❌ Agent is NOT loaded in launchctl."; \
	fi
	if pgrep -f "dock_hotkeys" > /dev/null; then \
		echo "✅ dock_hotkeys process is running:"; \
		ps -ef | grep "dock_hotkeys"; \
	else \
		echo "❌ dock_hotkeys process is NOT running."; \
	fi
	echo ""
	echo "Launch agent configuration:"
	cat "$(LAUNCH_AGENT_PATH)" 2>/dev/null || echo "⚠️ No plist file found at $(LAUNCH_AGENT_PATH)"
	echo
	echo "Checking log files:"
	echo "--- stderr log ---"
	if [ -f "$(HOME_LOG_DIR)/stderr.log" ]; then \
		tail -n 20 "$(HOME_LOG_DIR)/stderr.log"; \
	else \
		echo "⚠️ No error log found at $(HOME_LOG_DIR)/stderr.log"; \
	fi
	echo ""
	echo "--- stdout log ---"
	if [ -f ""$(HOME_LOG_DIR)"/stdout.log" ]; then \
		tail -n 20 "$(HOME_LOG_DIR)/stdout.log"; \
	else \
		echo "⚠️ No output log found at $(HOME_LOG_DIR)/stdout.log"; \
	fi

trim:
	find . -type f -not -path "*/\.*" -not -path "*/.build/*" -exec sed -i '' -E 's/[[:space:]]+$$//' {} \;
