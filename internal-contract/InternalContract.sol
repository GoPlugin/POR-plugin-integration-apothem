pragma solidity 0.4.24;

pragma experimental ABIEncoderV2;


import "@goplugin/contracts/src/v0.4/PluginClient.sol";
import "@goplugin/contracts/src/v0.4/interfaces/AggregatorInterface.sol";
import "@goplugin/contracts/src/v0.4/vendor/SignedSafeMath.sol";
import "@goplugin/contracts/src/v0.4/vendor/Ownable.sol";
import "@goplugin/contracts/src/v0.4/vendor/SafeMathPlugin.sol";

/**
 * @title An example Plugin contract with aggregation
 * @notice Requesters can use this contract as a framework for creating
 * requests to multiple Plugin nodes and running aggregation
 * as the contract receives answers.
 */
contract Aggregator is AggregatorInterface, PluginClient, Ownable {
  using SafeMathPlugin for uint256;
  using SignedSafeMath for int256;

  //Aggregate RequestId
  uint256 public _aggRequestId;

  //Oracle Fee 
  uint256 private ORACLE_PAYMENT = 0.1 * 10**18;

  //Struct to store the Answers 
  struct Answer {
    uint128 minimumResponses;
    uint128 maxResponses;
    int256[] responses;
  }

  //Struct to keep track of PLI Deposits
  struct PLIDatabase{
    address depositor;
    uint256 totalcredits;
  }

  mapping(address => PLIDatabase) public plidbs;

  //Events definition
  event ResponseReceived(int256 indexed response, uint256 indexed answerId, address indexed sender);
  event oracleFeeModified(address indexed owner,uint256 indexed oraclefee,uint256 timestamp);
  event PLIDeposited(address indexed depositer,uint256 depositedValue,uint256 timestamp);
  event EnabledAuthorizer(address indexed owner,address indexed customerContractAddress, address indexed walletAddress, bool isAllowed, uint256 timestamp);
  event TransferredPLI(address indexed owner,address indexed recipient,uint256 amount,uint256 timestamp);
  event DestroyedContract(address indexed owner,uint256 timestamp);
  event UpdatedRequestDetails(uint256 minimumResponses,string[] jobIds,address[] oracles,uint256 timestamp);



  int256 private currentAnswerValue;
  uint256 private updatedTimestampValue;
  uint256 private latestCompletedAnswer;
  uint128 public minimumResponses;
  string[] public jobIds;
  address[] public oracles;
  int256[] public oracleResponses;
  uint256 public totalResponseReceived;

  uint256 private answerCounter = 1;
  mapping(address => bool) public authorizedRequesters;
  mapping(bytes32 => uint256) private requestAnswers;
  mapping(uint256 => Answer) private answers;
  mapping(uint256 => int256) private currentAnswers;
  mapping(uint256 => uint256) private updatedTimestamps;
  mapping(address => mapping(address=>bool)) public authorizedWallets;
  uint256 private totalOracles;

  uint256 constant private MAX_ORACLE_COUNT = 28;

  /**
   * @notice Deploy with the address of the PLI token and arrays of matching
   * length containing the addresses of the oracles and their corresponding
   * Job IDs.
   * @dev Sets the PliToken address for the network, addresses of the oracles,
   * and jobIds in storage.
   * @param _pli The address of the PLI token
   * @param _minimumResponses the minimum number of responses
   * before an answer will be calculated
   * @param _oracles An array of oracle addresses
   * @param _jobIds An array of Job IDs
   */
  constructor(
    address _pli,
    uint128 _minimumResponses,
    address[] _oracles,
    string[] _jobIds
  ) public Ownable() {
    setPluginToken(_pli);
    updateRequestDetails(_minimumResponses, _oracles, _jobIds);
    totalOracles = _oracles.length;
    _aggRequestId = 1;
  }

  function depositPLI(uint256 _value) public returns(bool) {
      require(_value<=100*10**18,"NOT_MORE_THAN_100_ALLOWED");
      //Transfer PLI to contract
      PliTokenInterface pli = PliTokenInterface(pluginTokenAddress());
      pli.transferFrom(msg.sender,address(this),_value);
      //Track the PLI deposited for the user
      PLIDatabase memory _plidb = plidbs[msg.sender];
      uint256 _totalCredits = _plidb.totalcredits + _value;
      plidbs[msg.sender] = PLIDatabase(
        msg.sender,
        _totalCredits
      );
      emit PLIDeposited(msg.sender,_value,block.timestamp);
      return true;
  }

  /**
   * @notice Creates a Plugin request for each oracle in the oracles array.
   * @dev This example does not include request parameters. Reference any documentation
   * associated with the Job IDs used to determine the required parameters per-request.
   */
  function requestData(address _caller)
    external
    ensureAuthorizedRequester()
    returns(uint256 _aggreqid)
  {
    //Check the total Credits available for the user to perform the transaction
    require(authorizedWallets[msg.sender][_caller] == true || msg.sender == owner ,"request from unauthorized wallet address");
    uint256 _a_totalCredits = plidbs[_caller].totalcredits;
    require(totalOracles > 0,"INVALID ORACLES LENGTH");
    require(_a_totalCredits >= (ORACLE_PAYMENT * totalOracles),"NO_SUFFICIENT_CREDITS");
    plidbs[_caller].totalcredits = _a_totalCredits - (ORACLE_PAYMENT * totalOracles) ;

    Plugin.Request memory request;
    bytes32 requestId;
    uint256 oraclePayment = ORACLE_PAYMENT;

    for (uint i = 0; i < oracles.length; i++) {
      request = buildPluginRequest(stringToBytes32(jobIds[i]), this, this.pluginCallback.selector);
      request.add("_fsyms","XDC");
      request.add("_tsyms","USDT");
      request.addInt("times", 10000);
      requestId = sendPluginRequestTo(oracles[i], request, oraclePayment);
      
      
      requestAnswers[requestId] = answerCounter;
    }
    answers[answerCounter].minimumResponses = minimumResponses;
    answers[answerCounter].maxResponses = uint128(oracles.length);
    _aggreqid = answerCounter;
    _aggRequestId = answerCounter;
    emit NewRound(answerCounter, msg.sender, block.timestamp);
    answerCounter = answerCounter.add(1);
    
  }

  /**
   * @notice Receives the answer from the Plugin node.
   * @dev This function can only be called by the oracle that received the request.
   * @param _clRequestId The Plugin request ID associated with the answer
   * @param _response The answer provided by the Plugin node
   */
  function pluginCallback(bytes32 _clRequestId, int256 _response)
    external
  {
    validatePluginCallback(_clRequestId);

    uint256 answerId = requestAnswers[_clRequestId];
    delete requestAnswers[_clRequestId];

    answers[answerId].responses.push(_response);
    oracleResponses.push(_response);
    emit ResponseReceived(_response, answerId, msg.sender);
    updateLatestAnswer(answerId);
    deleteAnswer(answerId);
  }

  /**
   * @notice Updates the arrays of oracles and jobIds with new values,
   * overwriting the old values.
   * @dev Arrays are validated to be equal length.
   * @param _minimumResponses the minimum number of responses
   * before an answer will be calculated
   * @param _oracles An array of oracle addresses
   * @param _jobIds An array of Job IDs
   */
  function updateRequestDetails(
    uint128 _minimumResponses,
    address[] _oracles,
    string[] _jobIds
  )
    public
    onlyOwner()
    validateAnswerRequirements(_minimumResponses, _oracles, _jobIds)
  {
    minimumResponses = _minimumResponses;
    jobIds = _jobIds;
    oracles = _oracles;
    emit UpdatedRequestDetails(minimumResponses,jobIds,oracles,block.timestamp);
  }

  /**
   * @notice Allows the owner of the contract to withdraw any PLI balance
   * available on the contract.
   * @dev The contract will need to have a PLI balance in order to create requests.
   * @param _recipient The address to receive the PLI tokens
   * @param _amount The amount of PLI to send from the contract
   */
  function transferPLI(address _recipient, uint256 _amount)
    public
    onlyOwner()
  {
    PliTokenInterface pliToken = PliTokenInterface(pluginTokenAddress());
    require(pliToken.transfer(_recipient, _amount), "PLI transfer failed");
    emit TransferredPLI(msg.sender, _recipient, _amount,block.timestamp);
  }

  /**
   * @notice Called by the owner to permission other addresses to generate new
   * requests to oracles.
   * @param _customerContractAddress the address whose permissions are being set
   * @param _walletAddress the address of the wallet whose permissions are being set
   * @param _allowed boolean that determines whether the requester is
   * permissioned or not
   */
  function setAuthorization(address _customerContractAddress,address _walletAddress, bool _allowed)
    external
    onlyOwner()
  {
    authorizedRequesters[_customerContractAddress] = _allowed;
    authorizedWallets[_customerContractAddress][_walletAddress] = _allowed;
    emit EnabledAuthorizer(msg.sender,_customerContractAddress,_walletAddress,_allowed,block.timestamp);
  }

  /**
   * @notice Cancels an outstanding Plugin request.
   * The oracle contract requires the request ID and additional metadata to
   * validate the cancellation. Only old answers can be cancelled.
   * @param _requestId is the identifier for the plugin request being cancelled
   * @param _payment is the amount of PLI paid to the oracle for the request
   * @param _expiration is the time when the request expires
   */
  function cancelRequest(
    bytes32 _requestId,
    uint256 _payment,
    uint256 _expiration
  )
    external
    ensureAuthorizedRequester()
  {
    uint256 answerId = requestAnswers[_requestId];
    require(answerId < latestCompletedAnswer, "Cannot modify an in-progress answer");

    delete requestAnswers[_requestId];
    answers[answerId].responses.push(0);
    deleteAnswer(answerId);

    cancelPluginRequest(
      _requestId,
      _payment,
      this.pluginCallback.selector,
      _expiration
    );
  }

  /**
   * @notice Called by the owner to kill the contract. This transfers all PLI
   * balance and ETH balance (if there is any) to the owner.
   */
  function destroy()
    external
    onlyOwner()
  {
    PliTokenInterface pliToken = PliTokenInterface(pluginTokenAddress());
    transferPLI(owner, pliToken.balanceOf(address(this)));
    emit DestroyedContract(owner,block.timestamp);
    selfdestruct(owner);
  }

  /**
   * @dev Performs aggregation of the answers received from the Plugin nodes.
   * Assumes that at least half the oracles are honest and so can't contol the
   * middle of the ordered responses.
   * @param _answerId The answer ID associated with the group of requests
   */
  function updateLatestAnswer(uint256 _answerId)
    private
    ensureMinResponsesReceived(_answerId)
    ensureOnlyLatestAnswer(_answerId)
  {
    uint256 responseLength = answers[_answerId].responses.length;
    uint256 middleIndex = responseLength.div(2);
    int256 currentAnswerTemp;

    totalResponseReceived =  answers[_answerId].responses.length;

    if (responseLength % 2 == 0) {
      int256 median1 = quickselect(answers[_answerId].responses, middleIndex);
      int256 median2 = quickselect(answers[_answerId].responses, middleIndex.add(1)); // quickselect is 1 indexed
      currentAnswerTemp = median1.add(median2) / 2; // signed integers are not supported by SafeMath
    } else {
      currentAnswerTemp = quickselect(answers[_answerId].responses, middleIndex.add(1)); // quickselect is 1 indexed
    }
    currentAnswerValue = currentAnswerTemp;
    latestCompletedAnswer = _answerId;
    updatedTimestampValue = now;
    updatedTimestamps[_answerId] = now;
    currentAnswers[_answerId] = currentAnswerTemp;
    emit AnswerUpdated(currentAnswerTemp, _answerId, now);
  }

  /**
   * @notice get the most recently reported answer
   */
  function getOracleResponses()
    external
    view
    returns (int256[])
  {
    return oracleResponses;
  }

  /**
   * @notice get the most recently reported answer
   */
  function latestAnswer()
    external
    view
    returns (int256)
  {
    return currentAnswers[latestCompletedAnswer];
  }

  function showPrice(uint256 _agreqId) public view returns(uint256,uint256){
    return(uint256(currentAnswers[_agreqId]),updatedTimestamps[_agreqId]);
  }
  /**
   * @notice get the last updated at block timestamp
   */
  function latestTimestamp()
    external
    view
    returns (uint256)
  {
    return updatedTimestamps[latestCompletedAnswer];
  }

  /**
   * @notice get past rounds answers
   * @param _roundId the answer number to retrieve the answer for
   */
  function getAnswer(uint256 _roundId)
    external
    view
    returns (int256)
  {
    return currentAnswers[_roundId];
  }

  /**
   * @notice get block timestamp when an answer was last updated
   * @param _roundId the answer number to retrieve the updated timestamp for
   */
  function getTimestamp(uint256 _roundId)
    external
    view
    returns (uint256)
  {
    return updatedTimestamps[_roundId];
  }

  /**
   * @notice get the latest completed round where the answer was updated
   */
  function latestRound()
    external
    view
    returns (uint256)
  {
    return latestCompletedAnswer;
  }

  /**
   * @dev Returns the kth value of the ordered array
   * See: http://www.cs.yale.edu/homes/aspnes/pinewiki/QuickSelect.html
   * @param _a The list of elements to pull from
   * @param _k The index, 1 based, of the elements you want to pull from when ordered
   */
  function quickselect(int256[] memory _a, uint256 _k)
    private
    pure
    returns (int256)
  {
    int256[] memory a = _a;
    uint256 k = _k;
    uint256 aLen = a.length;
    int256[] memory a1 = new int256[](aLen);
    int256[] memory a2 = new int256[](aLen);
    uint256 a1Len;
    uint256 a2Len;
    int256 pivot;
    uint256 i;

    while (true) {
      pivot = a[aLen.div(2)];
      a1Len = 0;
      a2Len = 0;
      for (i = 0; i < aLen; i++) {
        if (a[i] < pivot) {
          a1[a1Len] = a[i];
          a1Len++;
        } else if (a[i] > pivot) {
          a2[a2Len] = a[i];
          a2Len++;
        }
      }
      if (k <= a1Len) {
        aLen = a1Len;
        (a, a1) = swap(a, a1);
      } else if (k > (aLen.sub(a2Len))) {
        k = k.sub(aLen.sub(a2Len));
        aLen = a2Len;
        (a, a2) = swap(a, a2);
      } else {
        return pivot;
      }
    }
  }

    //set Oracle fee in wei
  function setOracleFee(uint256 _fee) public onlyOwner {
      require(_fee > 0,"invalid fee");
      require(_fee != ORACLE_PAYMENT,"input fee is same as existing fee");
      ORACLE_PAYMENT = _fee;
      emit oracleFeeModified(msg.sender,ORACLE_PAYMENT,block.timestamp);
  } 

  /**
   * @dev Swaps the pointers to two uint256 arrays in memory
   * @param _a The pointer to the first in memory array
   * @param _b The pointer to the second in memory array
   */
  function swap(int256[] memory _a, int256[] memory _b)
    private
    pure
    returns(int256[] memory, int256[] memory)
  {
    return (_b, _a);
  }

  /**
   * @dev Cleans up the answer record if all responses have been received.
   * @param _answerId The identifier of the answer to be deleted
   */
  function deleteAnswer(uint256 _answerId)
    private
    ensureAllResponsesReceived(_answerId)
  {
    delete answers[_answerId];
  }

  /**
   * @dev Prevents taking an action if the minimum number of responses has not
   * been received for an answer.
   * @param _answerId The the identifier of the answer that keeps track of the responses.
   */
  modifier ensureMinResponsesReceived(uint256 _answerId) {
    if (answers[_answerId].responses.length >= answers[_answerId].minimumResponses) {
      _;
    }
  }

  /**
   * @dev Prevents taking an action if not all responses are received for an answer.
   * @param _answerId The the identifier of the answer that keeps track of the responses.
   */
  modifier ensureAllResponsesReceived(uint256 _answerId) {
    if (answers[_answerId].responses.length == answers[_answerId].maxResponses) {
      _;
    }
  }

  /**
   * @dev Prevents taking an action if a newer answer has been recorded.
   * @param _answerId The current answer's identifier.
   * Answer IDs are in ascending order.
   */
  modifier ensureOnlyLatestAnswer(uint256 _answerId) {
    if (latestCompletedAnswer <= _answerId) {
      _;
    }
  }

  /**
   * @dev Ensures corresponding number of oracles and jobs.
   * @param _oracles The list of oracles.
   * @param _jobIds The list of jobs.
   */
  modifier validateAnswerRequirements(
    uint256 _minimumResponses,
    address[] _oracles,
    string[] _jobIds
  ) {
    require(_oracles.length <= MAX_ORACLE_COUNT, "cannot have more than 45 oracles");
    require(_oracles.length >= _minimumResponses, "must have at least as many oracles as responses");
    require(_oracles.length == _jobIds.length, "must have exactly as many oracles as job IDs");
    _;
  }

  /**
   * @dev Reverts if `msg.sender` is not authorized to make requests.
   */
  modifier ensureAuthorizedRequester() {
    require(authorizedRequesters[msg.sender] || msg.sender == owner, "Not an authorized address for creating requests");
    _;
  }

    //String to bytes to convert jobid to bytest32
  function stringToBytes32(string memory source) private pure returns (bytes32 result) {
    bytes memory tempEmptyStringTest = bytes(source);
    if (tempEmptyStringTest.length == 0) {
      return 0x0;
    }
    assembly { 
      result := mload(add(source, 32))
    }
  }

}
