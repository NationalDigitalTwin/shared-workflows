#!/usr/bin/env bash

ERRORS=0
function abort() {
    echo "  FAIL: $*" 1>&2
    if [ -z "${CONTINUE_ON_ERROR}" ]; then
      exit 1
    else
      ERRORS=$(( ${ERRORS} + 1))
    fi
}

function hardAbort() {
  abort "$*"
  exit 1
}

function requireCommand() {
  local COMMAND=$1
  if ! command -v ${COMMAND} >/dev/null 2>&1; then
    echo "Required command ${COMMAND} not found"
    exit 1
  fi
}

# Check necessary commands are present
requireCommand mvn
requireCommand xidel

function verified() {
    echo "  PASS: $*"
}

DIRECTORY=$1
pushd "${DIRECTORY}" || hardAbort "Invalid directory (${DIRECTORY}) supplied"

if [ ! -f pom.xml ]; then
  hardAbort "Not a Maven project, no top level pom.xml in ${DIRECTORY}"
fi

function getMavenProperty() {
    local POM=$1
    local PROPERTY=$2
    mvn -q -f "${POM}" -Dexec.executable=echo -Dexec.args="\${${PROPERTY}}" --non-recursive exec:exec
}

function hasMavenProperty() {
    local POM=$1
    local PROPERTY=$2
    local EXPECTED=$3
    local VALUE=$(getMavenProperty "${POM}" "${PROPERTY}")
    if [ -z "${VALUE}" ]; then
      abort "POM file ${POM} does not have the required Maven Property ${PROPERTY} set"
      return
    else
       local TRIMMED_VALUE=$(echo "${VALUE}" | tr -d ' ')
       if [ -z "${TRIMMED_VALUE}" ]; then
         abort "POM file ${POM} does not have the required Maven Property ${PROPERTY} set"
         return
       fi
    fi
    if [ -n "${EXPECTED}" ]; then
      if [ "${VALUE}" != "${EXPECTED}" ]; then
        abort "POM file ${POM} does not have the expected value for Maven Property ${PROPERTY} set, expected ${EXPECTED} but found ${VALUE}"
        return
      fi
    fi

    verified "Verified POM file ${POM} has required Maven Property ${PROPERTY} set as:"
    verified "${VALUE}"
}

function hasMavenConfiguration() {
    local POM=$1
    local XPATH=$2
    local DESCRIPTION=$3
    local EXPECTED=$4

    local VALUE=$(xidel -se "${XPATH}" "/tmp/pom.xml")

    if [ -z "${VALUE}" ]; then
      abort "POM file ${POM} does not have ${DESCRIPTION}"
      return
    fi
    if [ -n "${EXPECTED}" ]; then
      if [ "${EXPECTED}" != "${VALUE}" ]; then
        abort "POM file ${POM} does not have the expected value for ${DESCRIPTION}, expected ${EXPECTED} but found ${VALUE}"
        return
      fi
    fi
    
    verified "Verified POM file ${POM} has ${DESCRIPTION}"
}

function hasMavenArtifact() {
    local POM=$1
    local BUILD_DIR="$(dirname ${POM})/target/"
    local FILE=$2
    local DESCRIPTION=$2

    if [ ! -f "${BUILD_DIR}${FILE}" ]; then
      abort "POM file ${POM} does not produce a ${DESCRIPTION} in its target/ directory"
      return
    else
      verified "Verified POM file ${POM} produces a ${DESCRIPTION}"
    fi
}

echo "Quick Building the Maven Project..."
mvn clean install -DskipTests >/tmp/maven.log 2>&1
if [ $? -ne 0 ]; then
  cat /tmp/maven.log
  hardAbort "Maven Build Failed"
fi
echo "Maven Build completed"
echo "---"
echo

for POM in $(find . -name pom.xml); do
  echo "Testing POM file ${POM}..."
  pwd

  # Check for Basic Metadata
  echo "Basic Metadata Checks..."
  hasMavenProperty "${POM}" "project.version"
  hasMavenProperty "${POM}" "project.name"
  hasMavenProperty "${POM}" "project.description"
  hasMavenProperty "${POM}" "project.url"

  echo "Advanced Metadata Checks..."
  rm /tmp/pom.xml
  mvn -f "${POM}" help:effective-pom -Doutput=/tmp/pom.xml >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    abort "POM file ${POM} could not have an effective POM file generated for it"
    continue
  fi

  # Check for Licenses
  hasMavenConfiguration "${POM}" "//project[last()]/licenses[1]/license/url" "<licenses> section"

  # Check for Developers
  hasMavenConfiguration "${POM}" "//project[last()]/developers[1]/developer/email" "<developers> section" "opensource@telicent.io"

  # Check for SCM Information
  hasMavenConfiguration "${POM}" "//project[last()]/scm/url" "<scm> section"

  # Check for Distribution Management
  hasMavenConfiguration "${POM}" "//project[last()]/distributionManagement/repository/url" "<distributionManagement> section" "https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/"

  # Check nothing is pointing at AWS CodeArtifact
  grep -F "telicent-098669589541.d.codeartifact" "${POM}" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    abort "POM file ${POM} still contains a reference to Telicent AWS CodeArtifact"
  else
    verified "POM file ${POM} does not reference Telicent AWS CodeArtifact"
  fi
  
  # Check nothing is pointing at private GitHub organisation
  grep -Fi "/telicent-io/" "${POM}" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    abort "POM file ${POM} still contains a reference to the private telicent-io GitHub organisation"
  else
    verified "POM file ${POM} does not reference private telicent-io GitHub organisation"
  fi

  # Check aritifacts
  echo "Artifact Checks..."
  PACKAGING=$(getMavenProperty "${POM}" "project.packaging")
  ARTIFACT_ID=$(getMavenProperty "${POM}" "project.artifactId")
  VERSION=$(getMavenProperty "${POM}" "project.version")
  FINAL_NAME=$(getMavenProperty "${POM}" "project.build.finalName")
  echo "POM file ${POM} has packaging type ${PACKAGING}"

  if [ "${PACKAGING}" != "pom" ]; then
    hasMavenArtifact "${POM}" "${FINAL_NAME}.jar" "JAR File"
    hasMavenArtifact "${POM}" "${FINAL_NAME}-sources.jar" "Sources JAR"
    hasMavenArtifact "${POM}" "${FINAL_NAME}-javadoc.jar" "Javadoc JAR"
  fi
  hasMavenArtifact "${POM}" "${ARTIFACT_ID}-${VERSION}-bom.json" "JSON SBOM"
  hasMavenArtifact "${POM}" "${ARTIFACT_ID}-${VERSION}-bom.xml" "XML SBOM"

  # Verifying Signatures are present
  echo "Signature Checks..."
  for ARTIFACT in $(find "$(dirname ${POM})/target" -type f -not -name "*.asc" -d 1); do
    EXTENSION=${ARTIFACT##*.}
    case ${EXTENSION} in
      "txt"|"log")
        continue
        ;;
      *)
        if [[ "${ARTIFACT}" =~ original* ]]; then
          # We ignore original- artifacts as those won't be slated for release
          continue
        elif [ ! -f "${ARTIFACT}.asc" ]; then
          abort "POM file ${POM} produces artifact ${ARTIFACT} that does not have a corresponding digital signature file"
        else
          verified "Verified POM file ${POM} generates digital signature for artifact ${ARTIFACT}"
        fi
        ;;
    esac
  done

  echo "---"
  echo
done

if [ ${ERRORS} -gt 0 ]; then
  echo "Maven Project in ${DIRECTORY} had various errors, please see above output for details"
  exit 1
else
  echo "Maven Project in ${DIRECTORY} appears ready for Maven Central"
fi
