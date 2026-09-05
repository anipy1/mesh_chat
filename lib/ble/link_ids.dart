/// The service every node advertises, and the only service we ever scan for.
///
/// Scanning is always filtered on this UUID. That keeps us from connecting to
/// every wireless earbud in the building, and on iOS it is the only way to find
/// a peer whose app is in the background.
const kServiceUuidString = '6f5d0001-9c4a-4b2e-8f11-2a7c9d3e5b80';

/// Peripheral to central. Centrals subscribe to this, and we notify on it.
const kTxCharacteristicUuidString = '6f5d0002-9c4a-4b2e-8f11-2a7c9d3e5b80';

/// Central to peripheral. Centrals write to this, and we get a write request.
const kRxCharacteristicUuidString = '6f5d0003-9c4a-4b2e-8f11-2a7c9d3e5b80';

/// Prefix on the advertised name, so a scan can tell our app apart from
/// anything else that happens to expose the same service.
const kNamePrefix = 'MC-';
