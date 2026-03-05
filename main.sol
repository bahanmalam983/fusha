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
        regions[8] = 6; regions[9] = 7; regions[10] = 8; regions[11] = 2;
        regions[12] = 0; regions[13] = 0; regions[14] = 1; regions[15] = 2;
        regions[16] = 4; regions[17] = 9; regions[18] = 7; regions[19] = 0;
        regions[20] = 0; regions[21] = 0;
        for (uint256 i = 0; i < ids.length && _destIdList.length < MAX_DESTINATIONS; i++) {
            if (_destinations[ids[i]].destId != bytes32(0)) continue;
            _destinations[ids[i]] = Destination({
                destId: ids[i],
                regionCode: regions[i],
                nameHash: keccak256(abi.encodePacked(ids[i], block.number + i)),
                listedAtBlock: block.number,
                active: true
            });
            _destIdList.push(ids[i]);
        }
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyCurator() {
        if (msg.sender != guideCurator) revert Fusha_NotCurator();
        _;
    }

    modifier onlyCouncil() {
        if (msg.sender != council) revert Fusha_NotCouncil();
        _;
    }

    modifier nonReentrant() {
        if (_guard != 0) revert Fusha_Reentrancy();
        _guard = 1;
        _;
        _guard = 0;
    }

    // -------------------------------------------------------------------------
    // DESTINATIONS (curator)
    // -------------------------------------------------------------------------

    function listDestination(bytes32 destId, uint8 regionCode, bytes32 nameHash) external onlyCurator whenNotPaused {
        if (destId == bytes32(0)) revert Fusha_ZeroDestId();
        if (_destinations[destId].destId != bytes32(0)) revert Fusha_DestAlreadyListed();
        if (_destIdList.length >= MAX_DESTINATIONS) revert Fusha_MaxDestinationsReached();
        if (regionCode > MAX_REGION_CODE) revert Fusha_InvalidRegion();
        _destinations[destId] = Destination({
            destId: destId,
            regionCode: regionCode,
            nameHash: nameHash,
            listedAtBlock: block.number,
            active: true
        });
        _destIdList.push(destId);
        emit DestinationListed(destId, regionCode, nameHash, block.number, msg.sender);
    }

    function listDestinationBatch(
        bytes32[] calldata destIds,
        uint8[] calldata regionCodes,
        bytes32[] calldata nameHashes
    ) external onlyCurator whenNotPaused {
        uint256 n = destIds.length;
        if (n == 0 || n > MAX_BATCH_LIST) revert Fusha_BatchTooLarge();
        if (n != regionCodes.length || n != nameHashes.length) revert Fusha_ArrayLengthMismatch();
        if (_destIdList.length + n > MAX_DESTINATIONS) revert Fusha_MaxDestinationsReached();
        for (uint256 i = 0; i < n;) {
            bytes32 did = destIds[i];
            if (did != bytes32(0) && _destinations[did].destId == bytes32(0) && regionCodes[i] <= MAX_REGION_CODE) {
                _destinations[did] = Destination({
                    destId: did,
                    regionCode: regionCodes[i],
                    nameHash: nameHashes[i],
                    listedAtBlock: block.number,
                    active: true
                });
                _destIdList.push(did);
            }
            unchecked { ++i; }
        }
        emit BatchDestinationsListed(n, block.number);
    }

    function updateDestination(bytes32 destId, bytes32 nameHash) external onlyCurator whenNotPaused {
        if (destId == bytes32(0)) revert Fusha_ZeroDestId();
        Destination storage d = _destinations[destId];
        if (d.destId == bytes32(0) || !d.active) revert Fusha_DestNotFound();
        d.nameHash = nameHash;
        emit DestinationUpdated(destId, nameHash, block.number);
    }

    function retireDestination(bytes32 destId) external onlyCurator whenNotPaused {
        if (destId == bytes32(0)) revert Fusha_ZeroDestId();
        Destination storage d = _destinations[destId];
        if (d.destId == bytes32(0)) revert Fusha_DestNotFound();
        d.active = false;
        emit DestinationRetired(destId, block.number);
    }

    // -------------------------------------------------------------------------
    // ITINERARIES (anyone)
    // -------------------------------------------------------------------------

    function createItinerary(bytes32[] calldata destIds, uint256 durationDays) external whenNotPaused returns (uint256 itineraryId) {
        if (destIds.length == 0) revert Fusha_EmptyItinerary();
        if (destIds.length > MAX_ITINERARY_STOPS) revert Fusha_ItineraryTooLong();
        if (durationDays < MIN_ITINERARY_DAYS || durationDays > MAX_ITINERARY_DAYS) revert Fusha_DurationOutOfRange();
        itineraryId = ++_itineraryCounter;
        bytes32[] memory stored = new bytes32[](destIds.length);
        for (uint256 i = 0; i < destIds.length;) {
            stored[i] = destIds[i];
            unchecked { ++i; }
        }
        _itineraries[itineraryId] = Itinerary({
            itineraryId: itineraryId,
            destIds: stored,
            durationDays: durationDays,
            creator: msg.sender,
            createdAtBlock: block.number,
            exists: true
        });
        emit ItineraryCreated(itineraryId, stored, durationDays, msg.sender, block.number);
        return itineraryId;
    }

    function editItinerary(uint256 itineraryId, bytes32[] calldata destIds, uint256 durationDays) external whenNotPaused {
        if (itineraryId == 0 || !_itineraries[itineraryId].exists) revert Fusha_InvalidItineraryId();
        Itinerary storage it = _itineraries[itineraryId];
        if (it.creator != msg.sender) revert Fusha_NotItineraryCreator();
        if (destIds.length == 0) revert Fusha_EmptyItinerary();
        if (destIds.length > MAX_ITINERARY_STOPS) revert Fusha_ItineraryTooLong();
        if (durationDays < MIN_ITINERARY_DAYS || durationDays > MAX_ITINERARY_DAYS) revert Fusha_DurationOutOfRange();
        it.destIds = destIds;
        it.durationDays = durationDays;
        emit ItineraryEdited(itineraryId, block.number);
    }

    // -------------------------------------------------------------------------
    // REVIEWS (travelers)
    // -------------------------------------------------------------------------

    function postReview(bytes32 destId, uint8 rating, bytes32 reviewHash) external nonReentrant whenNotPaused {
        if (destId == bytes32(0)) revert Fusha_ZeroDestId();
        Destination storage d = _destinations[destId];
        if (d.destId == bytes32(0) || !d.active) revert Fusha_DestNotFound();
        if (rating < RATING_MIN || rating > RATING_MAX) revert Fusha_InvalidRating();
        if (block.number < _lastReviewBlock[msg.sender] + REVIEW_COOLDOWN_BLOCKS) {
            emit ReviewCooldown(_lastReviewBlock[msg.sender] + REVIEW_COOLDOWN_BLOCKS, msg.sender);
            revert Fusha_ReviewCooldown();
        }
        if (_reviewCountByDestAndTraveler[destId][msg.sender] >= MAX_REVIEWS_PER_DEST_PER_TRAVELER) revert Fusha_MaxReviewsPerDest();
        _lastReviewBlock[msg.sender] = block.number;
        _reviewCountByDestAndTraveler[destId][msg.sender]++;
        _reviews.push(ReviewRecord({
            destId: destId,
            traveler: msg.sender,
            rating: rating,
            reviewHash: reviewHash,
            atBlock: block.number
        }));
        emit ReviewPosted(destId, msg.sender, rating, reviewHash, block.number);
    }

    // -------------------------------------------------------------------------
    // TIPS (travelers -> guides, fee to treasury)
    // -------------------------------------------------------------------------

    function sendTip(address guide) external payable nonReentrant whenNotPaused {
        if (guide == address(0)) revert Fusha_ZeroAddress();
        if (msg.value == 0) revert Fusha_ZeroAmount();
        if (msg.value > MAX_TIP_WEI) revert Fusha_ZeroAmount();
        if (!_guideListed[guide]) revert Fusha_GuideNotRegistered();
        uint256 feeWei = (msg.value * TIP_FEE_BP) / BP_DENOMINATOR;
        uint256 toGuide = msg.value - feeWei;
        totalTipsWei += msg.value;
        totalTipsFeesWei += feeWei;
        treasuryBalance += feeWei;
        (bool ok,) = guide.call{ value: toGuide }("");
        require(ok, "Fusha: transfer failed");
        emit TipSent(msg.sender, guide, msg.value, feeWei, block.number);
    }

    function topTreasury() external payable {
        if (msg.value == 0) return;
        treasuryBalance += msg.value;
        emit TreasuryTopped(msg.value, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // GUIDES (curator)
    // -------------------------------------------------------------------------

    function registerGuide(address guide, bytes32 profileHash) external onlyCurator whenNotPaused {
        if (guide == address(0)) revert Fusha_ZeroAddress();
        if (_guideListed[guide]) revert Fusha_GuideAlreadyRegistered();
        _guideProfiles[guide] = profileHash;
        _guideListed[guide] = true;
        _guideList.push(guide);
        emit GuideRegistered(guide, profileHash, block.number);
    }

    function unlistGuide(address guide) external onlyCurator whenNotPaused {
        if (guide == address(0)) revert Fusha_ZeroAddress();
        if (!_guideListed[guide]) revert Fusha_GuideNotRegistered();
        _guideListed[guide] = false;
        emit GuideUnlisted(guide, block.number);
    }

    // -------------------------------------------------------------------------
    // COUNCIL (pause, season)
    // -------------------------------------------------------------------------

    function togglePause() external onlyCouncil {
        if (paused()) _unpause(); else _pause();
        emit CouncilToggledPause(paused(), block.number);
    }

    function advanceSeason() external {
        if (msg.sender != guideCurator && msg.sender != council) revert Fusha_InvalidSeasonRoller();
        uint256 prev = currentSeason;
        currentSeason++;
        emit SeasonAdvanced(prev, currentSeason, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEWS: Destinations
    // -------------------------------------------------------------------------

    function destinationCount() external view returns (uint256) {
        return _destIdList.length;
    }

    function destIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _destIdList.length) revert Fusha_InvalidIndex();
        return _destIdList[index];
    }

    function getDestination(bytes32 destId) external view returns (
        bytes32 id,
        uint8 regionCode,
        bytes32 nameHash,
        uint256 listedAtBlock,
        bool active
    ) {
        Destination storage d = _destinations[destId];
        if (d.destId == bytes32(0)) revert Fusha_DestNotFound();
        return (d.destId, d.regionCode, d.nameHash, d.listedAtBlock, d.active);
    }

    function isDestinationActive(bytes32 destId) external view returns (bool) {
        return _destinations[destId].active && _destinations[destId].destId != bytes32(0);
    }

    function getDestinationsByRegion(uint8 regionCode) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _destIdList.length; i++) {
            if (_destinations[_destIdList[i]].regionCode == regionCode && _destinations[_destIdList[i]].active) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _destIdList.length; i++) {
            if (_destinations[_destIdList[i]].regionCode == regionCode && _destinations[_destIdList[i]].active) {
                ids[j++] = _destIdList[i];
            }
        }
    }

    function getDestinationRange(uint256 fromIndex, uint256 limit) external view returns (
        bytes32[] memory destIds,
        uint8[] memory regionCodes,
        bool[] memory activeFlags
    ) {
        uint256 total = _destIdList.length;
        if (fromIndex >= total) return (new bytes32[](0), new uint8[](0), new bool[](0));
        uint256 end = fromIndex + limit;
        if (end > total) end = total;
        uint256 n = end - fromIndex;
        destIds = new bytes32[](n);
        regionCodes = new uint8[](n);
        activeFlags = new bool[](n);
        for (uint256 i = 0; i < n;) {
            bytes32 did = _destIdList[fromIndex + i];
            Destination storage d = _destinations[did];
            destIds[i] = d.destId;
            regionCodes[i] = d.regionCode;
            activeFlags[i] = d.active;
            unchecked { ++i; }
        }
    }

    // -------------------------------------------------------------------------
    // VIEWS: Itineraries
    // -------------------------------------------------------------------------

    function getItinerary(uint256 itineraryId) external view returns (
        uint256 id,
        bytes32[] memory destIds,
        uint256 durationDays,
        address creator,
        uint256 createdAtBlock
    ) {
        if (itineraryId == 0 || !_itineraries[itineraryId].exists) revert Fusha_InvalidItineraryId();
        Itinerary storage it = _itineraries[itineraryId];
        return (it.itineraryId, it.destIds, it.durationDays, it.creator, it.createdAtBlock);
    }

    function itineraryExists(uint256 itineraryId) external view returns (bool) {
        return _itineraries[itineraryId].exists;
    }

    function totalItineraries() external view returns (uint256) {
        return _itineraryCounter;
    }

    function getItineraryDestIds(uint256 itineraryId) external view returns (bytes32[] memory) {
        if (itineraryId == 0 || !_itineraries[itineraryId].exists) revert Fusha_InvalidItineraryId();
        return _itineraries[itineraryId].destIds;
    }

    // -------------------------------------------------------------------------
    // VIEWS: Reviews
    // -------------------------------------------------------------------------

    function reviewCount() external view returns (uint256) {
        return _reviews.length;
    }

    function getReview(uint256 index) external view returns (
        bytes32 destId,
        address traveler,
        uint8 rating,
        bytes32 reviewHash,
        uint256 atBlock
    ) {
        if (index >= _reviews.length) revert Fusha_InvalidIndex();
        ReviewRecord storage r = _reviews[index];
        return (r.destId, r.traveler, r.rating, r.reviewHash, r.atBlock);
    }

    function getReviewsForDestination(bytes32 destId, uint256 fromIndex, uint256 limit) external view returns (
        address[] memory travelers,
        uint8[] memory ratings,
        uint256[] memory atBlocks
    ) {
        uint256 count = 0;
        for (uint256 i = 0; i < _reviews.length; i++) {
            if (_reviews[i].destId == destId) count++;
        }
        if (fromIndex >= count) return (new address[](0), new uint8[](0), new uint256[](0));
        uint256 end = fromIndex + limit;
        if (end > count) end = count;
        uint256 n = end - fromIndex;
        travelers = new address[](n);
        ratings = new uint8[](n);
        atBlocks = new uint256[](n);
        uint256 skipped = 0;
        uint256 j = 0;
        for (uint256 i = 0; i < _reviews.length && j < n; i++) {
            if (_reviews[i].destId != destId) continue;
            if (skipped < fromIndex) { skipped++; continue; }
            travelers[j] = _reviews[i].traveler;
            ratings[j] = _reviews[i].rating;
            atBlocks[j] = _reviews[i].atBlock;
            j++;
        }
    }

    function averageRatingForDestination(bytes32 destId) external view returns (uint256 sum, uint256 count) {
        for (uint256 i = 0; i < _reviews.length; i++) {
            if (_reviews[i].destId == destId) {
                sum += _reviews[i].rating;
                count++;
            }
        }
    }

    function lastReviewBlockOf(address traveler) external view returns (uint256) {
        return _lastReviewBlock[traveler];
    }

    function reviewCountForDestAndTraveler(bytes32 destId, address traveler) external view returns (uint256) {
        return _reviewCountByDestAndTraveler[destId][traveler];
    }

    function canPostReview(address traveler, bytes32 destId) external view returns (bool) {
        if (destId == bytes32(0)) return false;
        if (_destinations[destId].destId == bytes32(0) || !_destinations[destId].active) return false;
        if (block.number < _lastReviewBlock[traveler] + REVIEW_COOLDOWN_BLOCKS) return false;
        return _reviewCountByDestAndTraveler[destId][traveler] < MAX_REVIEWS_PER_DEST_PER_TRAVELER;
    }

    // -------------------------------------------------------------------------
    // VIEWS: Guides
    // -------------------------------------------------------------------------

    function isGuide(address account) external view returns (bool) {
        return _guideListed[account];
    }

    function guideProfile(address guide) external view returns (bytes32) {
        return _guideProfiles[guide];
    }

    function guideListLength() external view returns (uint256) {
        return _guideList.length;
    }

    function guideAt(uint256 index) external view returns (address) {
        if (index >= _guideList.length) revert Fusha_InvalidIndex();
        return _guideList[index];
    }

    // -------------------------------------------------------------------------
    // VIEWS: Config & snapshot
    // -------------------------------------------------------------------------

    function getCurator() external view returns (address) {
        return guideCurator;
    }

    function getTreasury() external view returns (address) {
        return tipTreasury;
    }

    function getCouncil() external view returns (address) {
        return council;
    }

    function getGenesisBlock() external view returns (uint256) {
        return genesisBlock;
    }

    function getConfigSeed() external view returns (bytes32) {
        return configSeed;
    }

    function getVersion() external pure returns (uint256) {
        return FUSHA_VERSION;
    }

    function getNamespace() external pure returns (bytes32) {
        return FUSHA_NAMESPACE;
    }

    function getSnapshot() external view returns (
        uint256 destCount,
        uint256 itineraryCount,
        uint256 reviewCount_,
        uint256 season,
        uint256 totalTips,
        uint256 totalFees,
        uint256 treasuryBal
    ) {
        return (
            _destIdList.length,
            _itineraryCounter,
            _reviews.length,
            currentSeason,
            totalTipsWei,
            totalTipsFeesWei,
            treasuryBalance
        );
    }

    function getConstants() external pure returns (
        uint256 maxDestinations,
        uint256 maxItineraryStops,
        uint256 maxItineraryDays,
        uint256 reviewCooldownBlocks,
        uint256 maxReviewsPerDestPerTraveler,
        uint256 ratingMin,
        uint256 ratingMax,
        uint256 tipFeeBp,
        uint256 seasonBlocks
    ) {
        return (
            MAX_DESTINATIONS,
            MAX_ITINERARY_STOPS,
            MAX_ITINERARY_DAYS,
            REVIEW_COOLDOWN_BLOCKS,
            MAX_REVIEWS_PER_DEST_PER_TRAVELER,
            RATING_MIN,
            RATING_MAX,
            TIP_FEE_BP,
            SEASON_BLOCKS
        );
    }

    function currentBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function blocksUntilNextReviewAllowed(address traveler) external view returns (uint256) {
        uint256 next = _lastReviewBlock[traveler] + REVIEW_COOLDOWN_BLOCKS;
        if (block.number >= next) return 0;
        return next - block.number;
    }

    function getReviewRange(uint256 fromIndex, uint256 limit) external view returns (
        bytes32[] memory destIds,
        address[] memory travelers,
        uint8[] memory ratings,
        uint256[] memory atBlocks
    ) {
        uint256 total = _reviews.length;
        if (fromIndex >= total) return (new bytes32[](0), new address[](0), new uint8[](0), new uint256[](0));
        uint256 end = fromIndex + limit;
        if (end > total) end = total;
        uint256 n = end - fromIndex;
        destIds = new bytes32[](n);
        travelers = new address[](n);
        ratings = new uint8[](n);
        atBlocks = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            ReviewRecord storage r = _reviews[fromIndex + i];
            destIds[i] = r.destId;
            travelers[i] = r.traveler;
            ratings[i] = r.rating;
            atBlocks[i] = r.atBlock;
            unchecked { ++i; }
        }
    }

    function getTopRatedDestinations(uint256 limit) external view returns (bytes32[] memory destIds, uint256[] memory avgRatings) {
        if (limit == 0 || _destIdList.length == 0) return (new bytes32[](0), new uint256[](0));
        if (limit > _destIdList.length) limit = _destIdList.length;
        uint256[] memory sums = new uint256[](_destIdList.length);
        uint256[] memory counts = new uint256[](_destIdList.length);
        for (uint256 i = 0; i < _reviews.length; i++) {
            bytes32 did = _reviews[i].destId;
            for (uint256 j = 0; j < _destIdList.length; j++) {
                if (_destIdList[j] == did) {
                    sums[j] += _reviews[i].rating;
                    counts[j]++;
                    break;
                }
            }
        }
        uint256[] memory indices = new uint256[](_destIdList.length);
        for (uint256 i = 0; i < _destIdList.length; i++) indices[i] = i;
        for (uint256 i = 0; i < _destIdList.length; i++) {
            for (uint256 j = i + 1; j < _destIdList.length; j++) {
                uint256 a = counts[indices[i]] == 0 ? 0 : (sums[indices[i]] * 1e18) / counts[indices[i]];
                uint256 b = counts[indices[j]] == 0 ? 0 : (sums[indices[j]] * 1e18) / counts[indices[j]];
                if (b > a) {
                    (indices[i], indices[j]) = (indices[j], indices[i]);
                }
            }
        }
        uint256 outLen = limit;
        destIds = new bytes32[](outLen);
        avgRatings = new uint256[](outLen);
        for (uint256 i = 0; i < outLen; i++) {
            uint256 idx = indices[i];
            destIds[i] = _destIdList[idx];
            avgRatings[i] = counts[idx] == 0 ? 0 : (sums[idx] * 1e18) / counts[idx];
        }
    }

    function treasuryWithdraw(uint256 amountWei) external {
        if (msg.sender != tipTreasury) revert Fusha_NotCouncil();
        if (amountWei == 0 || amountWei > treasuryBalance) revert Fusha_ZeroAmount();
        treasuryBalance -= amountWei;
        (bool ok,) = msg.sender.call{ value: amountWei }("");
        require(ok, "Fusha: withdraw failed");
    }

    receive() external payable {
        treasuryBalance += msg.value;
        emit TreasuryTopped(msg.value, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // EXTRA VIEWS: Destinations (pagination, filters)
    // -------------------------------------------------------------------------

    function getActiveDestinations(uint256 fromIndex, uint256 limit) external view returns (
        bytes32[] memory destIds,
        uint8[] memory regionCodes,
        bytes32[] memory nameHashes
    ) {
        uint256 total = _destIdList.length;
        uint256 activeCount = 0;
        for (uint256 i = 0; i < total; i++) {
            if (_destinations[_destIdList[i]].active) activeCount++;
        }
        if (fromIndex >= activeCount) return (new bytes32[](0), new uint8[](0), new bytes32[](0));
        uint256 end = fromIndex + limit;
        if (end > activeCount) end = activeCount;
        uint256 n = end - fromIndex;
        destIds = new bytes32[](n);
        regionCodes = new uint8[](n);
        nameHashes = new bytes32[](n);
        uint256 skipped = 0;
        uint256 j = 0;
        for (uint256 i = 0; i < total && j < n; i++) {
            Destination storage d = _destinations[_destIdList[i]];
            if (!d.active) continue;
            if (skipped < fromIndex) { skipped++; continue; }
            destIds[j] = d.destId;
            regionCodes[j] = d.regionCode;
            nameHashes[j] = d.nameHash;
            j++;
        }
    }

    function activeDestinationCount() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _destIdList.length; i++) {
            if (_destinations[_destIdList[i]].active) c++;
        }
        return c;
    }

    function getDestinationsByIds(bytes32[] calldata ids) external view returns (
        uint8[] memory regionCodes,
        bytes32[] memory nameHashes,
        bool[] memory activeFlags
    ) {
        uint256 n = ids.length;
