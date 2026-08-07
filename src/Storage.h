#pragma once
// src/Storage.h — owns the microStore FileSystem instance that backs
// all persistent state: runtime config (/config.bin), Reticulum
// transport identity, and the path table.
//
// Split out of Transport so it can be mounted EARLY in setup() —
// before Config::load_or_defaults() runs, which needs the filesystem
// registered to read /config.bin. Transport used to own this during
// Phase 2 but the load-order dependency pushed it up.
//
// One job: mount the InternalFS partition and hand it to
// RNS::Utilities::OS via register_filesystem(). After init() returns
// successfully every subsystem that touches files via the RNS OS
// shim (Identity, path_store, Config) resolves to this instance.

namespace rlr { namespace storage {

// Initialise the internal flash filesystem and register it with the
// microReticulum OS shim. Must be called before any code that touches
// the filesystem — Config::load, Transport::init, Reticulum::start,
// Identity persistence. Returns true on success.
bool init();

// Delete the persisted Reticulum transport identity file, forcing a
// fresh Identity() to be generated on next boot. Needed to recover a
// device that generated its identity BEFORE the RNG entropy fix in
// main.cpp (see setup()'s comment) - such a device may share its LXMF
// address with another device flashed from the same build, and
// CONFIG RESET does not touch this file (it only resets /config.bin).
// Returns true if the file existed and was removed, false if it
// didn't exist (not an error - nothing to reset) or removal failed.
bool remove_identity();

}} // namespace rlr::storage
