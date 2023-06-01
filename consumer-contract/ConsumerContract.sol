pragma solidity ^0.4.24;


interface IInvokeOracle {
   function requestData(address _authorizedWalletAddress) external returns (uint256 requestId);
   function showPrice(uint256 _reqid) external view returns (uint256 answer, uint256 updatedOn);
}
contract ConsumerContract {
   address CONTRACTADDR = 0x4731B5D2376D94c504AbC0e9c8112d2D31925A10;
   uint256 public requestId;
   address private owner;
   constructor() public{
       owner = msg.sender;
   }
   //Fund this contract with sufficient PLI, before you trigger below function.
   //Note, below function will not trigger if you do not put PLI in above contract address
   function getPriceInfo() external returns (uint256) {
       require(msg.sender==owner,"Only owner can trigger this");
       (requestId) = IInvokeOracle(CONTRACTADDR).requestData({_authorizedWalletAddress:owner});
       return requestId;
   }
   //TODO - you can customize below function as you want, but below function will give you the pricing value
   //This function will give you last stored value in the contract
   function show(uint256 _id) external view returns (uint256, uint256) {
       (uint256 answer, uint256 updatedOn) = IInvokeOracle(CONTRACTADDR).showPrice({_reqid: _id});
       return (answer,updatedOn);
   }
}
