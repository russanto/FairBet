pragma solidity 0.4.19;


contract FairBet {

    address internal ceo;
    address internal bookmaker;
    BetEvent[] internal events;

    bytes32 constant STD_BET_GROUP = "STD_BET_GROUP";

    struct BetEvent {
        // address bookmaker;
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

        // Stores the amout of ether put on each bet-code
        mapping(bytes32 => uint256) betcodeAmounts;

        // Stores the amount of ether put on each bet-group
        mapping(bytes32 => uint256) betgroupAmounts;

        // Maps a betcode (key) to a betgroup (value). If a betcode is mapped to a betgroup it
        // is intented to be an allowed bet
        mapping(bytes32 => bytes32) allowedBetCodes;

        // Bet codes that must not accept new bet any more
        mapping(bytes32 => bool) retiredBetCodes;

        // Winning bet-codes (value) for each bet-group (key)
        mapping(bytes32 => bytes32) winningBetCodes;
    }

    struct Bet {
        address bettor;
        bytes32 betCode;
        uint256 amount;
        uint256 createTime;
    }

    modifier onlyBookmaker {
        require(bookmaker == msg.sender);
        _;
    }

    modifier onlyCeo {
        require(ceo == msg.sender);
        _;
    }

    function FairBet(address _ceo) public {
        ceo = _ceo;
        bookmaker = _ceo;
    }

    function changeBookmaker(address _newBookmaker) public onlyCeo {
        bookmaker = _newBookmaker;
    }

    function createEvent(
        string _description,
        uint256 _activeAfter,
        uint256 _endsAfter,
        uint256 _payableAfter,
        bytes32[] _stdAllowedBetCodes
    )
        public
        onlyBookmaker
        returns (uint256)
    {
        require((_endsAfter > _activeAfter) && (_payableAfter > _endsAfter));
        uint256 eventId = events.length++;
        BetEvent storage newEvent = events[eventId];
        newEvent.description = _description;
        newEvent.createTime = now;
        newEvent.activeAfter = _activeAfter;
        newEvent.endsAfter = _endsAfter;
        newEvent.payableAfter = _payableAfter;
        allowBetGroup(eventId, STD_BET_GROUP, _stdAllowedBetCodes);
        return eventId;
    }

    function allowBetGroup(uint256 _eventId, bytes32 _group, bytes32[] _betCodesToAllow) public onlyBookmaker {
        require(_group != "");

        BetEvent storage currEvent = events[_eventId];
        require(_isEventEditable(_eventId));

        // Ensure that a group with already bet set can't be modified
        require(currEvent.betgroupAmounts[_group] == 0);

        for (uint i = 0; i < _betCodesToAllow.length; i++) {
            currEvent.allowedBetCodes[_betCodesToAllow[i]] = _group;
        }
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
        currEvent.betgroupAmounts[currEvent.allowedBetCodes[_betCode]] += msg.value;
        currEvent.betcodeAmounts[_betCode] += msg.value;
    }

    function awardWin(uint256 _eventId, bytes32 _betCode) public onlyBookmaker {
        require(_isEventPayable(_eventId));
        BetEvent storage currEvent = events[_eventId];

        // Checks that there isn't an already awarded bet-code for his group
        require(uint256(currEvent.winningBetCodes[currEvent.allowedBetCodes[_betCode]]) == 0);

        currEvent.winningBetCodes[currEvent.allowedBetCodes[_betCode]] = _betCode;
    }

    function claimWin(uint256 _eventId, bytes32 _betCode, uint256 _betId, uint256 _createTime, uint256 _amount) public returns (bool) {
        // Check that the event is payable and that bet-code has been set as winning by bookmaker
        if (!_isEventPayable(_eventId) || !_isBetCodeWinning(_eventId, _betCode)) {
            return false;
        }

        // Check that sender really owns a winning bet
        var currBet = Bet({
            bettor: msg.sender,
            betCode: _betCode,
            amount: _amount,
            createTime: _createTime
        });

        BetEvent storage currEvent = events[_eventId];
        if (currEvent.betHashes[_betId] != keccak256(currBet)) {
            return false;
        }

        // Calculate amount to send
        var reward = _amount * currEvent.betgroupAmounts[currEvent.allowedBetCodes[_betCode]] / currEvent.betcodeAmounts[_betCode];

        msg.sender.transfer(reward);
        return true;
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

    function _isBetCodeAllowed(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        return ((uint256(events[_eventId].allowedBetCodes[_betCode]) != 0) && !(events[_eventId].retiredBetCodes[_betCode]));
    }

    function _isBetCodeWinning(uint256 _eventId, bytes32 _betCode) internal view returns (bool) {
        BetEvent storage currEvent = events[_eventId];
        return (currEvent.winningBetCodes[currEvent.allowedBetCodes[_betCode]] == _betCode);
    }
}
