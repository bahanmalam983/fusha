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
    error Fusha_ReviewCooldown();
    error Fusha_MaxReviewsPerDest();
    error Fusha_EmptyItinerary();
    error Fusha_ItineraryTooLong();
    error Fusha_InvalidItineraryId();
    error Fusha_NotItineraryCreator();
    error Fusha_GuideAlreadyRegistered();
    error Fusha_GuideNotRegistered();
    error Fusha_Reentrancy();
    error Fusha_ZeroAmount();
    error Fusha_ArrayLengthMismatch();
    error Fusha_BatchTooLarge();
    error Fusha_MaxDestinationsReached();
    error Fusha_InvalidIndex();
    error Fusha_DurationOutOfRange();
    error Fusha_InvalidSeasonRoller();

    // -------------------------------------------------------------------------
    // CONSTANTS (randomised within sensible ranges)
    // -------------------------------------------------------------------------

    uint256 public constant FUSHA_VERSION = 3;
    uint256 public constant MAX_DESTINATIONS = 412;
    uint256 public constant MAX_ITINERARY_STOPS = 28;
    uint256 public constant MAX_ITINERARY_DAYS = 90;
    uint256 public constant MIN_ITINERARY_DAYS = 1;
    uint256 public constant REVIEW_COOLDOWN_BLOCKS = 217;
    uint256 public constant MAX_REVIEWS_PER_DEST_PER_TRAVELER = 2;
    uint256 public constant RATING_MIN = 1;
    uint256 public constant RATING_MAX = 5;
    uint256 public constant TIP_FEE_BP = 87;
    uint256 public constant BP_DENOMINATOR = 10_000;
    uint256 public constant MAX_REGION_CODE = 24;
    uint256 public constant SEASON_BLOCKS = 604;
    uint256 public constant MAX_BATCH_LIST = 19;
    bytes32 public constant FUSHA_NAMESPACE = keccak256("fusha.travel.v3");
    uint256 public constant MAX_TIP_WEI = 50 ether;

    // -------------------------------------------------------------------------
    // IMMUTABLES (EIP-55, 40 hex chars)
    // -------------------------------------------------------------------------

    address public immutable guideCurator;
    address public immutable tipTreasury;
    address public immutable council;
    uint256 public immutable genesisBlock;
    bytes32 public immutable configSeed;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct Destination {
        bytes32 destId;
        uint8 regionCode;
        bytes32 nameHash;
        uint256 listedAtBlock;
        bool active;
    }

    struct Itinerary {
        uint256 itineraryId;
        bytes32[] destIds;
        uint256 durationDays;
        address creator;
        uint256 createdAtBlock;
        bool exists;
    }

