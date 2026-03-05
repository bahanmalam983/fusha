// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title fusha
/// @notice Kansai-style travel ledger for Asia: curators list destinations and itineraries; travelers post reviews and ratings. Tip jar and guide roster with immutable config.
/// @dev Deployed for the Hanami-12 regional tourism pilot on EVM mainnets. No ETH custody except optional tips to treasury.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/utils/Pausable.sol";

contract fusha is ReentrancyGuard, Pausable {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event DestinationListed(
        bytes32 indexed destId,
        uint8 regionCode,
        bytes32 nameHash,
        uint256 listedAtBlock,
        address indexed listedBy
    );
    event DestinationUpdated(bytes32 indexed destId, bytes32 nameHash, uint256 atBlock);
    event DestinationRetired(bytes32 indexed destId, uint256 atBlock);
    event ItineraryCreated(
        uint256 indexed itineraryId,
        bytes32[] destIds,
        uint256 durationDays,
        address indexed creator,
        uint256 atBlock
    );
    event ItineraryEdited(uint256 indexed itineraryId, uint256 atBlock);
    event ReviewPosted(
        bytes32 indexed destId,
        address indexed traveler,
        uint8 rating,
        bytes32 reviewHash,
        uint256 atBlock
    );
    event ReviewCooldown(uint256 nextAllowedBlock, address indexed traveler);
    event TipSent(
        address indexed fromAddr,
        address indexed guide,
        uint256 amountWei,
        uint256 feeWei,
        uint256 atBlock
    );
    event GuideRegistered(address indexed guide, bytes32 profileHash, uint256 atBlock);
    event GuideUnlisted(address indexed guide, uint256 atBlock);
    event CouncilToggledPause(bool paused, uint256 atBlock);
    event TreasuryTopped(uint256 amountWei, address indexed fromAddr, uint256 atBlock);
    event SeasonAdvanced(uint256 previousSeason, uint256 newSeason, uint256 atBlock);
    event MaxReviewsPerDestUpdated(uint256 oldVal, uint256 newVal, uint256 atBlock);
    event BatchDestinationsListed(uint256 count, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error Fusha_NotCurator();
    error Fusha_NotCouncil();
    error Fusha_ZeroAddress();
    error Fusha_ZeroDestId();
    error Fusha_DestNotFound();
    error Fusha_DestAlreadyListed();
    error Fusha_DestRetired();
    error Fusha_InvalidRegion();
    error Fusha_InvalidRating();
