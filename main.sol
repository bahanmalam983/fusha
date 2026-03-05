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

    struct ReviewRecord {
        bytes32 destId;
        address traveler;
        uint8 rating;
        bytes32 reviewHash;
        uint256 atBlock;
    }

    mapping(bytes32 => Destination) private _destinations;
    bytes32[] private _destIdList;
    mapping(uint256 => Itinerary) private _itineraries;
    uint256 private _itineraryCounter;
    ReviewRecord[] private _reviews;
    mapping(bytes32 => mapping(address => uint256)) private _reviewCountByDestAndTraveler;
    mapping(address => uint256) private _lastReviewBlock;
    mapping(address => bytes32) private _guideProfiles;
    mapping(address => bool) private _guideListed;
    address[] private _guideList;
    uint256 public currentSeason;
    uint256 public totalTipsWei;
    uint256 public totalTipsFeesWei;
    uint256 public treasuryBalance;
    uint256 private _guard;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        guideCurator = address(0x7E2c4A8f0B3d6E9a1C5f8D2b5e0A3c6D9F1b4E7a0);
        tipTreasury = address(0x9A1c3e5B7d0F2a4C6e8A0b2D4f6A8c0E2b4D6F8a0);
        council = address(0x2D5F8a1B4e7C0f3A6d9E2b5F8a1C4e7D0f3A6B9e2);
        genesisBlock = block.number;
        configSeed = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, block.chainid));
        currentSeason = 0;
        totalTipsWei = 0;
        totalTipsFeesWei = 0;
        treasuryBalance = 0;
        _itineraryCounter = 0;
        _seedInitialDestinations();
    }

    function _seedInitialDestinations() private {
        bytes32[] memory ids = new bytes32[](22);
        uint8[] memory regions = new uint8[](22);
        ids[0] = keccak256("dest_tokyo_shibuya");
        ids[1] = keccak256("dest_kyoto_fushimi");
        ids[2] = keccak256("dest_osaka_dotonbori");
        ids[3] = keccak256("dest_seoul_myeongdong");
        ids[4] = keccak256("dest_bangkok_khaosan");
        ids[5] = keccak256("dest_taipei_101");
        ids[6] = keccak256("dest_hanoi_old_quarter");
        ids[7] = keccak256("dest_singapore_marina");
        ids[8] = keccak256("dest_hong_kong_kowloon");
        ids[9] = keccak256("dest_shanghai_bund");
        ids[10] = keccak256("dest_bali_ubud");
        ids[11] = keccak256("dest_phuket_patong");
        ids[12] = keccak256("dest_nara_todaiji");
        ids[13] = keccak256("dest_hiroshima_miyajima");
        ids[14] = keccak256("dest_busan_haeundae");
        ids[15] = keccak256("dest_chiang_mai_old_city");
        ids[16] = keccak256("dest_ho_chi_minh_pham_ngu_lao");
        ids[17] = keccak256("dest_kuala_lumpur_petronas");
        ids[18] = keccak256("dest_beijing_forbidden");
        ids[19] = keccak256("dest_nagoya_castle");
        ids[20] = keccak256("dest_sapporo_odori");
        ids[21] = keccak256("dest_okinawa_churaumi");
        regions[0] = 0; regions[1] = 0; regions[2] = 0; regions[3] = 1;
        regions[4] = 2; regions[5] = 3; regions[6] = 4; regions[7] = 5;
