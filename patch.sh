#!/usr/bin/env bash
# Patch main.go to use features from patches.go
TARGET_FILE=$(find -name main.go)

if [ ! -f "$TARGET_FILE" ]; then
    echo "Error: $TARGET_FILE not found."
    exit 1
fi

inject_after_line() {
    local target_line="$1"
    local hook_to_add="$2"

    if grep -q "$hook_to_add" "$TARGET_FILE"; then
        echo "Hook '$hook_to_add' is already present in $TARGET_FILE. Skipping modification."
        return 0
    fi

    echo "Injecting '$hook_to_add' after '$target_line' in $TARGET_FILE..."

    local escaped_target
    escaped_target=$(printf '%s' "$target_line" | sed 's/[.[\*^$()]/\\&/g')

    sed -i 's/\('"$escaped_target"'.*\)/\1\n\t'"$hook_to_add"'/g' "$TARGET_FILE"

    if grep -q "$hook_to_add" "$TARGET_FILE"; then
        echo "Successfully updated $TARGET_FILE with $hook_to_add!"
    else
        echo "Error: Failed to patch $TARGET_FILE with $hook_to_add."
        exit 1
    fi
}

inject_after_context() {
    local context_block="$1"
    local hook_to_add="$2"

    if grep -qF "$hook_to_add" "$TARGET_FILE"; then
        echo "Hook already present in $TARGET_FILE. Skipping modification."
        return 0
    fi

    echo "Injecting hook into the matched context block..."
    awk -v ctx="$context_block" -v hook="\t\t\t\t\t$hook_to_add" '
    BEGIN {
        RS = "^$"
    }
    {
        # Safely find the exact block and append the hook
        idx = index($0, ctx)
        if (idx > 0) {
            # Print up to the end of the context block, inject newline + indented hook, then print the rest
            end_ctx = idx + length(ctx)
            printf "%s\n%s%s", substr($0, 1, end_ctx-1), hook, substr($0, end_ctx)
        } else {
            print $0
        }
    }
    ' "$TARGET_FILE" > "${TARGET_FILE}.tmp" && mv "${TARGET_FILE}.tmp" "$TARGET_FILE"

    # Double-check if the operation succeeded
    if grep -qF "$hook_to_add" "$TARGET_FILE"; then
        echo "Successfully updated $TARGET_FILE!"
    else
        echo "Error: Failed to find the unique context block in $TARGET_FILE."
        exit 1
    fi
}

REMOTE_TCP_CONTEXT=$(cat << 'EOF'
					r, err := net.DialTCP("tcp", nil, mapping.Mapped)
					if err != nil {
						logger.Errorf("Failed to connect to %s: %s", mapping.Mapped, err)
						_ = c.Close()
						continue
					}
EOF
)

REMOTE_UDP_CONTEXT=$(cat << 'EOF'
					}
					if bytesRead == 0 {
						continue
					}
EOF
)

inject_after_line "flag.Parse()" "InitPatches()"
inject_after_line "nameserver :=" "SetupPatchesFlags()"
inject_after_context "$REMOTE_TCP_CONTEXT" 'if !ProcessRemoteTCP(logger, n.core.MTU(), c, r) { continue }'
inject_after_context "$REMOTE_UDP_CONTEXT" 'if !IsIPAllowed(remoteUdpAddr) { continue }'

OLD_BLOCK=$(cat << 'EOF'
if !ProcessRemoteTCP(logger, n.core.MTU(), c, r) { continue }
					go types.ProxyTCP(n.core.MTU(), c, r)
EOF
)

NEW_BLOCK=$(cat << 'EOF'
if !ProcessRemoteTCP(logger, n.core.MTU(), c, r) { continue }
					//go types.ProxyTCP(n.core.MTU(), c, r)
EOF
)

awk -v old="$OLD_BLOCK" -v new="$NEW_BLOCK" '
BEGIN { RS = "^$" }
{
    idx = index($0, old)
    if (idx > 0) {
        printf "%s%s%s", substr($0, 1, idx-1), new, substr($0, idx + length(old))
    } else {
        print $0
    }
}
' "$TARGET_FILE" > "${TARGET_FILE}.tmp" && mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
