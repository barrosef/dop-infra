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
#    and the image has to work with it. It is an IMAGE requirement, not
#    a deployment one — that is why the workspace belongs to group 0 with write
#    permission, which is how the arbitrary user manages to write.
FROM alpine:3.22

# TODO: git, bash, curl and ca-certificates come in here once the build has
# network access to the apk index. Without them the agent has a shell and
# nothing else — enough to prove the execution path, not to work in a real
# repository.

# The workspace is what SURVIVES suspension (the port's guarantee 5), and the
# exec starts here (guarantee 14).
RUN mkdir -p /workspace \
 && chgrp -R 0 /workspace \
 && chmod -R g=u /workspace
WORKDIR /workspace

USER 1001

# It stays up until somebody tells it to stop. The work comes in through exec.
CMD ["sleep", "infinity"]
