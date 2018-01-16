pragma solidity 0.4.19;


contract FairBetAccessControl {
    address public ceo;
    address public bookmakersManager;

    enum BookmakerStatus {
        Banned,
        Allowed,
        Certified
    }

    mapping(address => BookmakerStatus) public bookmakers;

    modifier onlyCeo {
        require(ceo == msg.sender);
        _;
    }

    modifier onlyBookmakerManager {
        require(bookmakersManager == msg.sender);
        _;
    }

    function setCEO(address _newCEO) external onlyCeo {
        ceo = _newCEO;
    }

    function setBookmakerManager(address _newBookmakersManager) external onlyCeo {
        bookmakersManager = _newBookmakersManager;
    }

    function setBookmakerStatus(address _bookmaker, BookmakerStatus _newStatus) external onlyBookmakerManager {
        bookmakers[_bookmaker] = _newStatus;
    }

    function isBookmakerStatusAtLeast(
        address _bookmaker,
        BookmakerStatus _status
    ) public returns (bool) {
        return uint8(bookmakers[_bookmaker]) >= uint8(_status);
    }
}


contract FairBet is FairBetAccessControl {

    BetEvent[] public events;

    bytes32 public constant STD_BET_GROUP = "STD_BET_GROUP";

    event BetEventCreated(
        uint256 id,
        string description,
        uint256 createTime,
        uint256 activeAfter,
        uint256 endsAfter,
        uint256 payableAfter
    );

    event BetGroupAllowed(
        uint256 eventId,
        bytes32 group,
        bytes32[] betCodesToAllow
    );

    event BetGroupGetPayable(
        uint256 eventId,
        bytes32 winnerBetCode,
        bool refund
    );

    struct BetEvent {
        // Bookmaker is the main responsible of the event
        address bookmaker;

        // Description of the event
        string description;

        // time bet event has been created
        uint256 createTime;

        // delay to begin accepting bets
        uint256 activeAfter;

        // delay to stop accepting bets
        uint256 endsAfter;

        // delay to award winners and claim prizes
        uint256 payableAfter;

        // Hashes of bets
        bytes32[] betHashes;

        // Stores the groups of possible bets. BetGroupCode as key and the bet group data as value
        mapping(bytes32 => BetGroup) betGroups;

        // Stores the possible bets data. BetCode as key and the BetCode data as value
        mapping(bytes32 => BetCode) betCodes;

        // Stores the amout of ether put on each bet-code
        //mapping(bytes32 => uint256) betcodeAmounts;

        // Stores the amount of ether put on each bet-group
        //mapping(bytes32 => uint256) betgroupAmounts;

        // Stored the amount of ether rewarded for each betgroup
        //mapping(bytes32 => uint256) betgroupAmountsReturned;

        // Maps a betcode (key) to a betgroup (value). If a betcode is mapped to a betgroup it
        // is intented to be an allowed bet
        //mapping(bytes32 => bytes32) allowedBetCodes;

        // Winning bet-codes (value) for each bet-group (key)
        //mapping(bytes32 => bytes32) winningBetCodes;
    }

    struct Bet {
        address bettor;
        bytes32 betCode;
        uint256 amount;
        uint256 createTime;
    }

    struct BetGroup {
        bytes32[] codes;
        uint256 amountBet;
        uint256 amountReturned;
        bytes32 winningBetCode;
    }

    struct BetCode {
        bytes32 group;
        uint256 amountBet;
        BetCodeStatus status;
    }

    enum BetCodeStatus {
        Denied, Allowed, Winning, Refund
    }

    function FairBet() public {
        ceo = msg.sender;
        bookmakersManager = msg.sender;
    }

    function createEvent(
        string _description,
        uint256 _activeAfter,
        uint256 _endsAfter,
        uint256 _payableAfter,
        bytes32[] _stdAllowedBetCodes
    )
        public
        returns (uint256)
    {
        require(isBookmakerStatusAtLeast(msg.sender, BookmakerStatus.Allowed));
        require((_endsAfter > _activeAfter) && (_payableAfter > _endsAfter));
        uint256 eventId = events.length++;
        BetEvent storage newEvent = events[eventId];
        newEvent.bookmaker = msg.sender;
        newEvent.description = _description;
        newEvent.createTime = now;
        newEvent.activeAfter = _activeAfter;
        newEvent.endsAfter = _endsAfter;
        newEvent.payableAfter = _payableAfter;
        BetEventCreated(eventId, _description, newEvent.createTime, _activeAfter, _endsAfter, _payableAfter);
        allowBetGroup(eventId, STD_BET_GROUP, _stdAllowedBetCodes);
        return eventId;
    }

    function allowBetGroup(uint256 _eventId, bytes32 _group, bytes32[] _betCodesToAllow) public {
        require(_isEventBookmaker(_eventId, msg.sender));
        require(_group != "");
        require(_betCodesToAllow.length <= 2**8);

        BetEvent storage currEvent = events[_eventId];
        require(_isEventEditable(_eventId));

        BetGroup storage currBetGroup = currEvent.betGroups[_group];

        // Ensure that a group with already bet set can't be modified
        require(currBetGroup.amountBet == 0);

        for (uint8 i = 0; i < _betCodesToAllow.length; i++) {
            currBetGroup.codes.push(_betCodesToAllow[i]);
            currEvent.betCodes[_betCodesToAllow[i]].group = _group;
            currEvent.betCodes[_betCodesToAllow[i]].status = BetCodeStatus.Allowed;
        }
        BetGroupAllowed(_eventId, _group, _betCodesToAllow);
    }

    function bet(uint256 _eventId, bytes32 _betCode) public payable returns (uint256 createTime, uint256 betId) {
        require(_isEventActive(_eventId));
        require(_isBetCodeAllowed(_eventId, _betCode));
        BetEvent storage currEvent = events[_eventId];
        createTime = now;
        var currBet = Bet({
            bettor: msg.sender,
            betCode: _betCode,
            amount: msg.value,
            createTime: createTime
        });
        betId = currEvent.betHashes.push(keccak256(currBet)) - 1;
        currEvent.betGroups[currEvent.betCodes[_betCode].group].amountBet += msg.value;
        currEvent.betCodes[_betCode].amountBet += msg.value;
    }

    function awardWin(uint256 _eventId, bytes32 _betCode) public returns (bool) {
        require(_isEventPayable(_eventId));
        require(_isEventBookmaker(_eventId, msg.sender));

        BetEvent storage currEvent = events[_eventId];
        BetCode storage winningBetCode = currEvent.betCodes[_betCode];

        // Checks that there isn't an already awarded bet-code for his group
        require(uint256(currEvent.betGroups[winningBetCode.group].winningBetCode) == 0);

        if (winningBetCode.amountBet == 0) {
            BetGroup storage currBetGroup = currEvent.betGroups[winningBetCode.group];
            for (uint8 i = 0; i < currBetGroup.codes.length; i++) {
                currEvent.betCodes[currBetGroup.codes[i]].status = BetCodeStatus.Refund;
            }
            BetGroupGetPayable(_eventId, _betCode, true);
            return false;
        } else {
            currEvent.betGroups[winningBetCode.group].winningBetCode = _betCode;
            winningBetCode.status = BetCodeStatus.Winning;
            BetGroupGetPayable(_eventId, _betCode, false);
            return true;
        }
    }

    function claimWin(
        uint256 _eventId,
        bytes32 _betCode,
        uint256 _betId,
        uint256 _createTime,
        uint256 _amount
    )
    public
    returns (bool) {
        require(_isEventPayable(_eventId));

        // Check that the bet-code has been set as winning by bookmaker and bet is registered
        if (
            !_isBetCodeWinning(_eventId, _betCode) ||
            !_isBetRegistered(_eventId, _betCode, _betId, _createTime, _amount)) {
            return false;
        }

        BetEvent storage currEvent = events[_eventId];
        BetGroup storage currBetGroup = currEvent.betGroups[currEvent.betCodes[_betCode].group];

        // Avoid user can claim again win for his bet
        currEvent.betHashes[_betId] = bytes32(0);

        // Calculate amount to send
        var reward = _amount * currBetGroup.amountBet / currEvent.betCodes[_betCode].amountBet;
        currBetGroup.amountReturned += reward;

        msg.sender.transfer(reward);
        return true;
    }

    function claimRefund() {

    }

    function _isEventActive(uint256 _eventId) internal view returns (bool) {
        BetEvent storage currEvent = events[_eventId];
        return (
            now > (currEvent.createTime + currEvent.activeAfter) &&
            now < (currEvent.createTime + currEvent.endsAfter)
        );
    }

    function _isEventEditable(uint256 _eventId) internal view returns (bool) {
        BetEvent storage currEvent = events[_eventId];
        return (
            now >= currEvent.createTime &&
            now < (currEvent.createTime + currEvent.activeAfter
        ));
    }

    function _isEventEnded(uint256 _eventId) internal view returns (bool) {
        BetEvent storage currEvent = events[_eventId];
        return ((currEvent.createTime + currEvent.endsAfter) < now);
    }

    function _isEventPayable(uint256 _eventId) internal view returns (bool) {
        BetEvent storage currEvent = events[_eventId];
        return ((currEvent.createTime + currEvent.payableAfter) < now);
    }

    function _isEventBookmaker(uint256 _eventId, address _bookmaker) internal view returns (bool) {
        return (events[_eventId].bookmaker == _bookmaker);
    }

    function _isBetRegistered(uint256 _eventId, bytes32 _betCode, uint256 _betId, uint256 _createTime, uint256 _amount) internal view returns (bool) {
        var currBet = Bet({
            bettor: msg.sender,
            betCode: _betCode,
            amount: _amount,
            createTime: _createTime
        });

        if (events[_eventId].betHashes[_betId] != keccak256(currBet)) {
            return false;
        } else {
            return true;
        }
    }

    function _isBetCodeAllowed(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        return (events[_eventId].betCodes[_betCode].status == BetCodeStatus.Allowed);
    }

    function _isBetCodeWinning(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        return (events[_eventId].betCodes[_betCode].status == BetCodeStatus.Winning);
    }
}
