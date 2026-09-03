# The image of the sandbox where the agent works.
#
# Two requirements that look like details and are not:
#
# 1. **A long-running process.** The sandbox has to stay up for the agent to run
#    commands in it (`SandboxLauncher.Exec`). An image whose default command
#    ends — `alpine`, for instance — makes the container exit at once, and the
#    exec fails with "container is not running", which sends you looking in the
#    wrong place.
#
# 2. **An arbitrary NON-root user.** OKD/OpenShift assign a random UID by SCC,
#    and the image has to work with it. It is an IMAGE requirement, not a
#    deployment one — that is why the workspace belongs to group 0 with write
#    permission, which is how the arbitrary user manages to write.
FROM alpine:3.22

# git is what brings the shelf in and takes the agent's commits out (ADR-0028);
# the rest is what a developer expects at a shell.
RUN apk add --no-cache git bash curl ca-certificates

# The workspace is what SURVIVES suspension (the port's guarantee 5), and the
# exec starts here (guarantee 14). The shelf's directory and the token's are
# created here so the arbitrary user can write the first and read the second.
RUN mkdir -p /workspace /project /etc/dop /sessions \
 && chgrp -R 0 /workspace /project /etc/dop /sessions \
 && chmod -R g=u /workspace /project /etc/dop /sessions
# The git configuration goes in the SYSTEM file, at build time, and that is the
# only place it works. `docker exec` and `pods/exec` do NOT inherit what the
# entrypoint exported, and the user the sandbox runs as (arbitrary under OKD's
# SCC) has no home to hold a `~/.gitconfig`. `/etc/gitconfig` is written by root
# here and read by every uid afterwards.
#
#  - safe.directory: `/project` is created by root in this image and cloned into
#    by the sandbox's user; without this, git refuses the repository as
#    "dubious ownership" and the agent cannot commit;
#  - credential.helper: it prints the TOKEN FILE's content when git asks. The
#    token never enters a URL, an environment variable, `ps` or this file — what
#    is here is the path.
RUN git config --system --add safe.directory /project  && git config --system credential.helper       '!f() { echo username=dop; echo "password=$(cat "${DOP_GIT_TOKEN_FILE:-/etc/dop/git-token}")"; }; f'

COPY entrypoint.sh /usr/local/bin/dop-entrypoint
RUN chmod 0755 /usr/local/bin/dop-entrypoint
WORKDIR /workspace

USER 1001

ENTRYPOINT ["/usr/local/bin/dop-entrypoint"]
# It stays up until somebody tells it to stop. The work comes in through exec.
CMD ["sleep", "infinity"]
