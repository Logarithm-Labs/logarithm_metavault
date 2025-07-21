# Overview

## Project Architecture

This project implements a modular, upgradeable vault system for asset management, supporting both standard ERC4626 vaults and custom "LogarithmVaults" with asynchronous withdrawal flows. The core architecture consists of:

- **MetaVault**: The main user-facing vault, managing deposits, withdrawals, and allocations to underlying vaults.
- **VaultFactory**: A factory contract for deploying new MetaVaults as proxies (upgradeable or minimal).
- **VaultRegistry**: A registry and approval system for vaults that can be used as allocation targets.

### Contract Relationships

- Users interact with MetaVaults for deposits/withdrawals.
- Owners of meta vaults allocate assets to registered/approved vaults (from VaultRegistry).
- VaultFactory deploys new MetaVaults and manages their upgradeability.

---

## Contract Descriptions

### 1. MetaVault (`src/MetaVault.sol`)

- **Type**: ERC4626-compliant vault, upgradeable, inherits from ManagedVault.
- **Purpose**: Aggregates user deposits, allocates assets to underlying vaults, and manages complex withdrawal flows (including async requests for LogarithmVaults).
- **Key Features**:
  - Supports both synchronous (ERC4626) and asynchronous (LogarithmVault) withdrawals.
  - Handles allocation and deallocation of assets to/from multiple vaults.
  - Implements a request/claim pattern for withdrawals when idle liquidity is insufficient.
  - Integrates with VaultRegistry for target vault approval.
  - Inherits fee logic (management/performance) from ManagedVault.
  - Can be shut down by the registry for emergency.

### 2. VaultFactory (`src/VaultFactory.sol`)

- **Type**: Factory, UpgradeableBeacon.
- **Purpose**: Deploys new MetaVaults as either upgradeable BeaconProxy contracts or minimal proxies.
- **Key Features**:
  - Permissionless vault creation.
  - Tracks all deployed proxies and their configurations.
  - Ensures all MetaVaults are initialized with correct parameters.
  - Provides utility functions for querying deployed vaults and their types.

### 3. VaultRegistry (`src/VaultRegistry.sol`)

- **Type**: Registry, UUPS upgradeable.
- **Purpose**: Maintains a list of vaults that can be used as allocation targets by MetaVaults.
- **Key Features**:
  - Only registered and approved vaults can receive allocations.
  - Agent can register vaults.
  - Owner can register, approve, or unapprove vaults.
  - Can trigger MetaVault shutdowns for safety.
