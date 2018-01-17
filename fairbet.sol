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
    ) public view returns (bool) {
        return uint8(bookmakers[_bookmaker]) >= uint8(_status);
    }
}


contract FairBet is FairBetAccessControl {

    BetEvent[] public events;

    Bet[] public bets;

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

        // Stores the groups of possible bets. BetGroupCode as key and the bet group data as value
        mapping(bytes32 => BetGroup) betGroups;

        // Stores the possible bets data. BetCode as key and the BetCode data as value
        mapping(bytes32 => BetCode) betCodes;

    }

    struct Bet {
        address bettor;
        uint256 eventId;
        bytes32 betCode;
        uint256 amount;
        uint256 createTime;
        bool payed;
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
        returns (uint256 eventId)
    {
        require(isBookmakerStatusAtLeast(msg.sender, BookmakerStatus.Allowed));
        require((_endsAfter > _activeAfter) && (_payableAfter > _endsAfter));
        BetEvent memory newEvent = BetEvent({
            bookmaker: msg.sender,
            description: _description,
            createTime: now,
            activeAfter: _activeAfter,
            endsAfter: _endsAfter,
            payableAfter: _payableAfter
        });
        eventId = events.push(newEvent) - 1;
        BetEventCreated(eventId, _description, newEvent.createTime, _activeAfter, _endsAfter, _payableAfter);
        allowBetGroup(eventId, STD_BET_GROUP, _stdAllowedBetCodes);
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

    function bet(uint256 _eventId, bytes32 _betCode) public payable returns (uint256 betId) {
        require(_isEventActive(_eventId));
        require(_isBetCodeAllowed(_eventId, _betCode));
        BetEvent storage currEvent = events[_eventId];
        betId = bets.push(Bet({
            bettor: msg.sender,
            eventId: _eventId,
            betCode: _betCode,
            amount: msg.value,
            createTime: now,
            payed: false
        })) - 1;
        currEvent.betGroups[currEvent.betCodes[_betCode].group].amountBet += msg.value;
        currEvent.betCodes[_betCode].amountBet += msg.value;
    }

    function awardWin(uint256 _eventId, bytes32 _betCode) public returns (bool) {
        require(
            _isEventPayable(_eventId) &&
            _isEventBookmaker(_eventId, msg.sender) &&
            _isBetCodeAllowed(_eventId, _betCode)
        );

        BetEvent storage currEvent = events[_eventId];
        BetCode storage winningBetCode = currEvent.betCodes[_betCode];

        // Checks that there isn't an already awarded bet-code for his group
        require(uint256(currEvent.betGroups[winningBetCode.group].winningBetCode) == 0);

        currEvent.betGroups[winningBetCode.group].winningBetCode = _betCode;

        if (winningBetCode.amountBet == 0) {
            BetGroup storage currBetGroup = currEvent.betGroups[winningBetCode.group];
            for (uint8 i = 0; i < currBetGroup.codes.length; i++) {
                currEvent.betCodes[currBetGroup.codes[i]].status = BetCodeStatus.Refund;
            }
            winningBetCode.status = BetCodeStatus.Winning;
            BetGroupGetPayable(_eventId, _betCode, true);
            return false;
        } else {
            winningBetCode.status = BetCodeStatus.Winning;
            BetGroupGetPayable(_eventId, _betCode, false);
            return true;
        }
    }

    function claimWin(uint256 _betId) external {

        Bet storage currBet = bets[_betId];
        BetEvent storage currEvent = events[currBet.eventId];

        // Bet code must be marked as winning and checks bet owner
        require(
            _isBetCodeWinning(currBet.eventId, currBet.betCode) &&
            checkBetOwner(msg.sender, _betId) &&
            !currBet.payed
        );

        BetGroup storage currBetGroup = currEvent.betGroups[currEvent.betCodes[currBet.betCode].group];

        // Avoid user can claim again win for his bet
        currBet.payed = true;

        // Calculate amount to send
        var reward = currBet.amount * currBetGroup.amountBet / currEvent.betCodes[currBet.betCode].amountBet;
        currBetGroup.amountReturned += reward;

        msg.sender.transfer(reward);
    }

    function claimRefund(uint256 _betId) external {

        Bet storage currBet = bets[_betId];
        BetEvent storage currEvent = events[currBet.eventId];

        // Bet code must be marked as refundable and checks bet owner
        require(
            _isBetCodeRefundable(currBet.eventId, currBet.betCode) &&
            checkBetOwner(msg.sender, _betId) &&
            !currBet.payed
        );

        // Avoid user can claim again refund for his bet
        currBet.payed = true;

        currEvent.betGroups[currEvent.betCodes[currBet.betCode].group].amountReturned += currBet.amount;
        msg.sender.transfer(currBet.amount);
    }

    function checkBetOwner(address _owner, uint256 _betId) public view returns (bool) {
        return (bets[_betId].bettor == _owner);
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

    function _isBetCodeAllowed(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        return (events[_eventId].betCodes[_betCode].status == BetCodeStatus.Allowed);
    }

    function _isBetCodeWinning(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        return (events[_eventId].betCodes[_betCode].status == BetCodeStatus.Winning);
    }

    function _isBetCodeRefundable(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        return (events[_eventId].betCodes[_betCode].status == BetCodeStatus.Refund);
    }
}
