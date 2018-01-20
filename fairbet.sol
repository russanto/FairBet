pragma solidity 0.4.19;


contract Upgradable {

    event ContractUpgrade(address newContract);

    address public newContractAddress;

    function upgradeContract(address _upgradedContractAddress) public {
        newContractAddress = _upgradedContractAddress;
        ContractUpgrade(newContractAddress);
    }
}

contract FairBetAccessControl is Upgradable {
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

    modifier onlyCeo {
        require(ceoAddress == msg.sender);
        _;
    }

    modifier onlyCfo {
        require(cfoAddress == msg.sender);
        _;
    }

    modifier onlyBookmakerManager {
        require(bookmakersManager == msg.sender);
        _;
    }

    modifier whenPaused {
        require(contractStatus == ContractStatus.Paused);
        _;
    }

    modifier atMostClaim {
        require(uint8(contractStatus) < 2);
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
        if (newContractAddress != address(0))
            require(uint8(_newStatus) < uint(contractStatus));
        contractStatus = _newStatus;
    }

    function upgradeContract(address _upgradedContractAddress) public onlyCeo atMostClaim {
        super.upgradeContract(_upgradedContractAddress);
    }
}

contract FairBetBase is FairBetAccessControl {

    event BetEventCreated(
        uint256 id,
        string description,
        uint64 createTime,
        uint64 activeAfterTime,
        uint64 endsAfterTime,
        uint64 payableAfterTime
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
        // Bookmaker is the main responsible of the event
        address bookmaker;

        // Description of the event
        string description;

        // Bet fee in 1/1000 of bet value on each bet
        uint16 betFee;

        // time bet event has been created in seconds (block timestamp)
        uint64 createTime;

        // delay from createTime to begin accepting bets
        uint64 activeAfterTime;

        // delay to stop accepting bets
        uint64 endsAfterTime;

        // delay to award winners and claim prizes
        uint64 payableAfterTime;

        // amount of fee in wei that bookmaker will gain
        uint256 collectedFees;

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

    function _isEventEditable(BetEvent storage _event) internal view returns (bool) {
        return (
            now >= _event.createTime &&
            now < _event.activeAfterTime
        );
    }

    function _isEventActive(BetEvent storage _event) internal view returns (bool) {
        return (
            now >= _event.activeAfterTime &&
            now < _event.endsAfterTime
        );
    }

    function _isEventEnded(BetEvent storage _event) internal view returns (bool) {
        return _event.endsAfterTime < now;
    }

    function _isEventPayable(BetEvent storage _event) internal view returns (bool) {
        return _event.payableAfterTime < now;
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

contract FairBetBookmakers is FairBetBase {

    enum BookmakerStatus {
        Banned,
        Allowed,
        Certified
    }

    struct Bookmaker {
        BookmakerStatus status;
        uint256 earnedFees;
    }

    mapping(address => BookmakerStatus) public bookmakers;

    modifier allowedBookmaker {
        require(uint8(bookmakers[msg.sender]) >= uint8(BookmakerStatus.Allowed));
        _;
    }

    function setBookmakerStatus(address _bookmaker, BookmakerStatus _newStatus) external onlyBookmakerManager {
        bookmakers[_bookmaker] = _newStatus;
    }
}

contract FairBetFee is FairBetBookmakers {
    uint256 public betEventCreationFee;
    uint256 public betCodeCreationFee;
    uint256 public betCreationFee;

    uint256 public collectedFees;

    event BetEventCreationFeeChanged(uint256 newFee);
    event BetCodeCreationFeeChanged(uint256 newFee);
    event BetCreationFeeChanged(uint256 newFee);

    function setBetEventCreationFee(uint256 _newFee) external onlyCfo {
        betEventCreationFee = _newFee;
        BetEventCreationFeeChanged(_newFee);
    }

    function setBetCodeCreationFee(uint256 _newFee) external onlyCfo {
        betCodeCreationFee = _newFee;
        BetCodeCreationFeeChanged(_newFee);
    }

    function setBetCreationFee(uint256 _newFee) external onlyCfo {
        betCreationFee = _newFee;
        BetCreationFeeChanged(_newFee);
    }

    function withdrawFees() external onlyCfo {
        var fees = collectedFees;
        collectedFees = 0;
        cfoAddress.transfer(fees);
    }

    function _payBetEventCreationFee() internal {
        require(
            msg.value >= betEventCreationFee &&
            (collectedFees + msg.value) > collectedFees
        );
        collectedFees += msg.value;
    }

    function _payBetCodeCreationFee(uint8 _quantity) internal {
        require(
            msg.value >= (betCodeCreationFee * _quantity) &&
            (collectedFees + msg.value) > collectedFees
        );
        collectedFees += msg.value;
    }

    function _payBetCreationFee() internal {
        require(
            msg.value >= betCodeCreationFee &&
            (collectedFees + msg.value) > collectedFees
        );
        collectedFees += msg.value;
    }
}

contract FairBet is FairBetFee {

    BetEvent[] public events;

    Bet[] public bets;

    bytes16 public constant STD_BET_GROUP = "STD_BET_GROUP";

    event DonationReceived(
        address from,
        uint256 amount
    );

    /**
     * Constructor set contract creator as CEO, CFO and BookmakersManager
     */
    function FairBet() public {
        ceoAddress = msg.sender;
        cfoAddress = msg.sender;
        bookmakersManager = msg.sender;
    }

    function() payable public {
        DonationReceived(msg.sender, msg.value);
    }

    /**
     * Function to create events on which bet.
     * Only bookmakers allowed by bookmakers manager can create events.
     *
     * A default bet-group is created. Bet-groups are immutable and can only be
     * overwritten if and only if there aren't bets on them
     *
     * @notice Provide meaningful bet-codes because, with the eventId, they're enough to place bets.
     * @notice Bet-codes must be unique inside the same event, regardless the group they belong to.
     *
     * @param _description A custom description string for the event
     * @param _activeAfter # of minutes starting from now when begin accepting bets
     * @param _endsAfter # of minutes starting from now when end accepting bets
     * @param _payableAfter # of minutes starting from now when bettor can select winner bet-code
     * @param _stdAllowedBetCodes list of bet-code to assign to a std group for the event
     *
     * @return eventId the ID of the newly created event
     */
    function createEvent(
        string _description,
        uint16 _appliedBetFee,
        uint16 _activeAfter,
        uint16 _endsAfter,
        uint32 _payableAfter,
        bytes16[] _stdAllowedBetCodes
    )
        public
        payable
        allowedBookmaker
        eventCreationAllowed
        returns (uint256 eventId)
    {
        _payBetEventCreationFee();
        require((_endsAfter > _activeAfter) && (_payableAfter > uint32(_endsAfter)));
        BetEvent memory newEvent = BetEvent({
            bookmaker: msg.sender,
            betFee: _appliedBetFee,
            description: _description,
            createTime: uint64(now),
            activeAfterTime: uint64(now) + (_activeAfter * 1 minutes),
            endsAfterTime: uint64(now) + (_endsAfter * 1 minutes),
            payableAfterTime: uint64(now) + (_payableAfter * 1 minutes)
        });
        eventId = events.push(newEvent) - 1;
        BetEventCreated(eventId, _description, newEvent.createTime, _activeAfter, _endsAfter, _payableAfter);
        allowBetGroup(eventId, STD_BET_GROUP, _stdAllowedBetCodes);
    }

    /**
     * Bookmakers of the BetEvent can create multiple bet-groups for their event.
     * Bet-groups are immutable and can only be overwritten if and only if
     * there aren't bets on them
     * Call again this function with the same group-code to overwrite that group
     *
     * @notice Bet-group code that you provide here is not necessary for placing bets.
     *  Bet-group code is only necessary if you want to overwrite that group of bet-codes.
     * @notice Provide meaningful bet-codes because, with the eventId, they're enough to place bets.
     * @notice Bet-codes must be unique inside the same event, regardless the group they belong to.
     *
     * @param _eventId BetEvent ID to which add Bet-groups
     * @param _group A code to assign to the group. It must be unique for the event unless you want to overwrite an existing bet-group.
     * @param _betCodesToAllow List of codes on which bettor can bet.
     */
    function allowBetGroup(
        uint256 _eventId,
        bytes16 _group,
        bytes16[] _betCodesToAllow
    )
    public
    payable
    eventCreationAllowed
    {
        BetEvent storage currEvent = events[_eventId];

        require(
            (_group != "") &&
            (_betCodesToAllow.length <= 2**8)
        );

        _payBetCodeCreationFee(uint8(_betCodesToAllow.length));

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

    /**
     * Place a bet on the event on the provided bet-code
     *
     * @notice Please, keep in mind or store the bet ID returned from this function. It is necessary to claim your win or refound.
     *
     * @param _eventId The event ID on which place the bet
     * @param _betCode The code of the bet to place
     *
     * @return betId Bet ID of the successfully placed bet
     */
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

    /**
     * Declares a bet-code winning for a bet-group and allow related bets to claim their win.
     * Be careful because this function operation can't be undone
     *
     * @notice ONLY 1 bet-code can be awarded to be winning for each bet-group.
     *
     * @param _eventId Your event ID
     * @param _betCode Winning bet-code
     *
     * @return true if there were bets on the winning bet-code: this will allow win claiming
     *  false if there weren't bets on the winning bet-code: this will allow bet refound for losers
     *
     */
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

    /**
     * Called by bettor who wants to claim for his winning bet.
     *
     * @param _betId Unique bet ID obtained when bet was placed
     */
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

    /**
     * Called by bettor who wants to claim for his refound when no one bet on the winning bet-code.
     *
     * @param _betId Unique bet ID obtained when bet was placed
     */
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

    /**
     * Check that address is the owner of the provided bet ID
     *
     * @param _owner the address to verify
     * @param _betId the ID of the bet to check
     *
     * @return true if address is owner, otherwise false
     */
    function checkBetOwner(address _owner, uint256 _betId) public claimAllowed view returns (bool) {
        return (bets[_betId].bettor == _owner);
    }
}
