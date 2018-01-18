pragma solidity 0.4.19;


contract Upgradable {

    event ContractUpgrade(address newContract);

    address public newContractAddress;

    function upgradeContract(address _upgradedContractAddress) public {
        newContractAddress = _upgradedContractAddress;
    }
}

contract FairBetAccessControl {
    address public ceoAddress;
    address public cfoAddress;
    address public bookmakersManager;

    ContractStatus public contractStatus = ContractStatus.Opened;

    enum ContractStatus {
        Paused,
        BetClaim,
        BetAllow,
        Opened
    }

    enum BookmakerStatus {
        Banned,
        Allowed,
        Certified
    }

    mapping(address => BookmakerStatus) public bookmakers;

    modifier onlyCeo {
        require(ceoAddress == msg.sender);
        _;
    }

    modifier onlyBookmakerManager {
        require(bookmakersManager == msg.sender);
        _;
    }

    modifier allowedBookmaker {
        require(uint8(bookmakers[msg.sender]) >= uint8(BookmakerStatus.Allowed));
        _;
    }

    modifier whenPaused {
        require(contractStatus == ContractStatus.Paused);
        _;
    }

    modifier claimAllowed {
        require(uint8(contractStatus) > 0);
        _;
    }

    modifier betAllowed {
        require(uint8(contractStatus) > 1);
        _;
    }

    modifier eventCreationAllowed {
        require(uint8(contractStatus) > 2);
        _;
    }

    function setCEO(address _newCEO) external onlyCeo {
        ceoAddress = _newCEO;
    }

    function setCFO(address _newCFO) external onlyCeo {
        cfoAddress = _newCFO;
    }

    function setBookmakerManager(address _newBookmakersManager) external onlyCeo {
        bookmakersManager = _newBookmakersManager;
    }

    function changeContractStatus(ContractStatus _newStatus) external onlyCeo {
        require(uint(_newStatus) < 4);
        contractStatus = _newStatus;
    }

    function setBookmakerStatus(address _bookmaker, BookmakerStatus _newStatus) external onlyBookmakerManager {
        bookmakers[_bookmaker] = _newStatus;
    }
}


contract FairBet is FairBetAccessControl, Upgradable {

    BetEvent[] public events;

    Bet[] public bets;

    bytes16 public constant STD_BET_GROUP = "STD_BET_GROUP";

    event BetEventCreated(
        uint256 id,
        string description,
        uint64 createTime,
        uint8 activeAfter,
        uint16 endsAfter,
        uint32 payableAfter
    );

    event BetGroupAllowed(
        uint256 eventId,
        bytes16 group,
        bytes16[] betCodesToAllow
    );

    event BetGroupGetPayable(
        uint256 eventId,
        bytes16 winnerBetCode,
        bool refund
    );

    struct BetEvent {
        // time bet event has been created in seconds (block timestamp)
        uint64 createTime;

        // delay from createTime to begin accepting bets in minutes
        uint8 activeAfter;

        // delay to stop accepting bets in seconds
        uint16 endsAfter;

        // delay to award winners and claim prizes in seconds
        uint32 payableAfter;

        // Description of the event
        string description;

        // Bookmaker is the main responsible of the event
        address bookmaker;

        // Stores the groups of possible bets. BetGroupCode as key and the bet group data as value
        mapping(bytes16 => BetGroup) betGroups;

        // Stores the possible bets data. BetCode as key and the BetCode data as value
        mapping(bytes16 => BetCode) betCodes;

    }

    struct Bet {
        uint256 eventId;
        uint256 amount;
        uint64 createTime;
        address bettor;
        bool payed;
        bytes16 betCode;
    }

    struct BetGroup {
        bytes16[] codes;
        uint256 amountBet;
        uint256 amountReturned;
        bytes16 winningBetCode;
    }

    struct BetCode {
        bytes16 group;
        uint256 amountBet;
        BetCodeStatus status;
    }

    enum BetCodeStatus {
        Denied, Allowed, Winning, Refund
    }

    function FairBet() public {
        ceoAddress = msg.sender;
        bookmakersManager = msg.sender;
    }

    function createEvent(
        string _description,
        uint8 _activeAfter,
        uint16 _endsAfter,
        uint32 _payableAfter,
        bytes16[] _stdAllowedBetCodes
    )
        public
        allowedBookmaker
        eventCreationAllowed
        returns (uint256 eventId)
    {
        require((_endsAfter > _activeAfter) && (_payableAfter > _endsAfter));
        BetEvent memory newEvent = BetEvent({
            bookmaker: msg.sender,
            description: _description,
            createTime: uint64(now),
            activeAfter: _activeAfter,
            endsAfter: _endsAfter,
            payableAfter: _payableAfter
        });
        eventId = events.push(newEvent) - 1;
        BetEventCreated(eventId, _description, newEvent.createTime, _activeAfter, _endsAfter, _payableAfter);
        allowBetGroup(eventId, STD_BET_GROUP, _stdAllowedBetCodes);
    }

    function allowBetGroup(uint256 _eventId, bytes16 _group, bytes16[] _betCodesToAllow) public eventCreationAllowed {
        BetEvent storage currEvent = events[_eventId];

        require(
            (_group != "") &&
            (_betCodesToAllow.length <= 2**8)
        );

        require(
            _isEventBookmaker(currEvent, msg.sender) &&
            _isEventEditable(currEvent)
        );

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

    function bet(uint256 _eventId, bytes16 _betCode) public payable betAllowed returns (uint256 betId) {
        BetEvent storage currEvent = events[_eventId];
        require(
            _isEventActive(currEvent) &&
            _isBetCodeAllowed(currEvent, _betCode)
        );
        betId = bets.push(Bet({
            bettor: msg.sender,
            eventId: _eventId,
            betCode: _betCode,
            amount: msg.value,
            createTime: uint64(now),
            payed: false
        })) - 1;
        currEvent.betGroups[currEvent.betCodes[_betCode].group].amountBet += msg.value;
        currEvent.betCodes[_betCode].amountBet += msg.value;
    }

    function awardWin(uint256 _eventId, bytes16 _betCode) public claimAllowed returns (bool) {
        BetEvent storage currEvent = events[_eventId];

        require(
            _isEventPayable(currEvent) &&
            _isEventBookmaker(currEvent, msg.sender) &&
            _isBetCodeAllowed(currEvent, _betCode)
        );

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

    function claimWin(uint256 _betId) public claimAllowed {

        Bet storage currBet = bets[_betId];
        BetEvent storage currEvent = events[currBet.eventId];

        // Bet code must be marked as winning and checks bet owner
        require(
            _isBetCodeWinning(currEvent, currBet.betCode) &&
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

    function claimRefund(uint256 _betId) public claimAllowed {

        Bet storage currBet = bets[_betId];
        BetEvent storage currEvent = events[currBet.eventId];

        // Bet code must be marked as refundable and checks bet owner
        require(
            _isBetCodeRefundable(currEvent, currBet.betCode) &&
            checkBetOwner(msg.sender, _betId) &&
            !currBet.payed
        );

        // Avoid user can claim again refund for his bet
        currBet.payed = true;

        currEvent.betGroups[currEvent.betCodes[currBet.betCode].group].amountReturned += currBet.amount;
        msg.sender.transfer(currBet.amount);
    }

    function checkBetOwner(address _owner, uint256 _betId) public claimAllowed view returns (bool) {
        return (bets[_betId].bettor == _owner);
    }

    function upgradeContract(address _upgradedContractAddress) public onlyCeo whenPaused {
        super.upgradeContract(_upgradedContractAddress);
    }

    function _isEventActive(BetEvent storage _event) internal view returns (bool) {
        return (
            now > (_event.createTime + _event.activeAfter) &&
            now < (_event.createTime + _event.endsAfter)
        );
    }

    function _isEventEditable(BetEvent storage _event) internal view returns (bool) {
        return (
            now >= _event.createTime &&
            now < (_event.createTime + _event.activeAfter
        ));
    }

    function _isEventEnded(BetEvent storage _event) internal view returns (bool) {
        return ((_event.createTime + _event.endsAfter) < now);
    }

    function _isEventPayable(BetEvent storage _event) internal view returns (bool) {
        return ((_event.createTime + _event.payableAfter) < now);
    }

    function _isEventBookmaker(BetEvent storage _event, address _bookmaker) internal view returns (bool) {
        return (_event.bookmaker == _bookmaker);
    }

    function _isBetCodeAllowed(BetEvent storage _event, bytes16 _betCode) internal view returns (bool) {
        return (_event.betCodes[_betCode].status == BetCodeStatus.Allowed);
    }

    function _isBetCodeWinning(BetEvent storage _event, bytes16 _betCode) internal view returns (bool) {
        return (_event.betCodes[_betCode].status == BetCodeStatus.Winning);
    }

    function _isBetCodeRefundable(BetEvent storage _event, bytes16 _betCode) internal view returns (bool) {
        return (_event.betCodes[_betCode].status == BetCodeStatus.Refund);
    }
}
