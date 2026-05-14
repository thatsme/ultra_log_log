# Single-shot fixture generator for the UltraLogLog Elixir port.
#
# Cross-validates the Elixir encoding bit-for-bit against Hash4j
# (Dynatrace's Java reference implementation). The container is built
# once, run once, and then discarded — there is no daemon and no
# orchestration. Output lands directly in the host's test/fixtures/
# via the bind mount in generate.sh.
#
# Run via the sibling generate.sh, which handles the bind-mount.

FROM eclipse-temurin:21-jdk

# Pinned to the version the paper-reproduction repository validates
# against (dynatrace-research/ultraloglog-paper, hash4j submodule
# commit 95834ea9 ≡ v0.17.0). Do not bump without re-validating the
# encoding/merge byte-for-byte against the paper's reference outputs.
ARG HASH4J_VERSION=0.17.0
WORKDIR /work

# Hash4j is a single self-contained jar (no transitive runtime deps).
# https://central.sonatype.com/artifact/com.dynatrace.hash4j/hash4j
RUN curl -fsSL \
  "https://repo1.maven.org/maven2/com/dynatrace/hash4j/hash4j/${HASH4J_VERSION}/hash4j-${HASH4J_VERSION}.jar" \
  -o hash4j.jar

COPY GenerateFixtures.java .
RUN javac -cp hash4j.jar GenerateFixtures.java

CMD ["sh", "-c", "java -cp .:hash4j.jar GenerateFixtures /out"]
