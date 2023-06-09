# pre-requisites  
# do setup XDCPay Chrome Extension in your chrome  

# API info: 
API used: https://gateway.fluent.finance/v1/gateway/balances

# How to use the Result value:
All the 'availableBalance' from this API json output are summed up in the smart contract and multiplied by 10000.
Once the consumerContract is deployed and executed, it emits (0) the result from the API, (1) timestamp. 
End user should divide the result by 10000 and make use of the value.
Since, in solidity we cannot handle floating point numbers, we multiply the result values by 10000. 

# Check Instructions.pdf provided in this directory for detailed steps to follow
