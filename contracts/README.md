# UMI Capture contracts

This directory contains the public contracts for the UMI Capture iOS client
and source Python Receiver. Compatibility identifiers are
kept where changing them would break protocol v1; they are wire names, not
product ownership statements.

- [README.md](README.md): index of the public contract files.
- [capture-package.md](capture-package.md): ZIP integrity and provenance envelope.
- [compatibility.md](compatibility.md): supported implementations and retained identifiers.
- [protocol-v1.md](protocol-v1.md): timing, roles, commands, ACKs, and upload authorization.

The public [coordinate-frame explanation](../docs/public/coordinate-frames.md)
describes the retained iOS coordinate semantics. Processing workers and numeric
fixture stacks are not included in this source release.
