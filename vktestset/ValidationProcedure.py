import time
import re
from pprint import pformat
from datetime import datetime
from typing import List, Literal, Optional, Mapping, Any, Union

from pydantic import BaseModel, Field
from vktestset import kubernetes_api

class RecoverableError(RuntimeError):
    "An error time can fix, will wait timeout before giving up"
    pass

class TestFailure(RuntimeError):
    "An error indicating the test has failed. Give up immediately."
    def __init__(self, title, desc=""):
        RuntimeError.__init__(self, title)
        self.description = desc

    def __str__(self):
        return f"""{RuntimeError.__str__(self)}

        {self.description}
        """

PodStatus = Literal[
    'Pending', 
    'Running', 
    'Succeeded',
    'Completed',
    'Failed', 
    'Unknown', 
    ] 

Cleanable = Literal[
    'pod',
    'namespace',
    'service',
    'config_map',
    'secret',
    ]

CleanupCondition = Literal[
    'always',
    'never',
    'onSuccess',
    'onFailure',
    ]

RegexOperator = Literal[
    'Exists',
    'CountAtLeast',
    'CountAtMost',
    'CountExactly',
    'Is'
    ]


    

class CheckPod(BaseModel, extra='forbid'):
    """
    Describe a test on the status of a pod or of its containers.
    """
    name: str = Field(description="Name of the Pod")
    namespace: str = Field(description="Namespace where the Pod is defined")
    status: PodStatus = Field('Completed', description="Status of the pod for the test to succeed")

    def execute(self, k8s):
        pod = k8s.read_namespaced_pod(name=self.name, namespace=self.namespace)
        if self.status != "Failed" and pod.status.phase == "Failed":
            raise TestFailure(f"Pod {self.name}.{self.namespace} failed", str(pod))
        if pod.status.phase != self.status:
            raise RecoverableError()


class CheckLogs(BaseModel, extra='forbid'):
    """
    Descrive a test on the logs.
    """
    name:       str = Field(description="Name of the Pod")
    namespace:  str = Field(description="Namespace where the Pod is defined")
    regex:      str = Field(description="Regular expression to be applied to the log")
    operator:   RegexOperator = Field(
                    default='Exists', 
                    description="Operation to be applied on the output of the regular expression",
                    )
    container:  Optional[str] = Field(
                    default=None, 
                    description="Name of the container. Mandatory for multi-container pods.",
                    )
    value:      Optional[Union[str, int]] = Field(
                    default=None,
                    description="Value to check the result of the regex agains. Optional for `Exists` operator.",
                    )

    def execute(self, k8s):    
        """
        Perform the test.
        """
        log = k8s.read_namespaced_pod_log(
            self.name, 
            self.namespace, 
            container=self.container,
            insecure_skip_tls_verify_backend=True,
            )
        matches = re.findall(self.regex, log)
        print (matches)
        if self.operator in ['Exists'] and len(matches) <= 0: 
            raise RecoverableError(f"Expression {self.regex} does not match log: \n{log}")
        if self.operator in ['CountAtLeast', 'CountExactly'] and len(matches) < int(self.value): 
            raise RecoverableError(f"Expression {self.regex} not sufficiently repeated in log \n{log}")
        if self.operator in ['CountAtMost', 'CountExactly'] and len(matches) > int(self.value): 
            raise TestFailure(f"Found too many occurrencies of {self.regex}", log)
        if self.operator in ['Is'] and str(self.value) not in matches:
            raise RecoverableError(f"Expression {self.regex} returned matches: {matches}. {self.value} expected.\n{log}")



class CleanConfig(BaseModel, extra='forbid'):
    """
    Define the procedure to clean up things once the test is over.
    """
    type:       Cleanable = Field(
                    description="Kubernetes object to delete as part of the clean-up.",
                )
    name:       str = Field(
                    description="Name of the pod.",
                )
    namespace:  str = Field(
                    description="Namespace where to look for the pod.",
                )
    condition:  CleanupCondition = Field(
                    default='always',
                    description="Condition upon which",
                )

    def execute(self, k8s, succeeded: bool):
        """
        Perform the test.
        """
        clean_after_success = succeeded and self.condition in ['always', 'onSuccess']
        clean_after_failure = not succeeded and self.condition in ['always', 'onFailure']

        if clean_after_success or clean_after_failure:
            if self.type in ['namespace']:
                getattr(k8s, f"delete_{self.type}")(self.name)
            elif self.type in ['pod', 'service', 'config_map', 'secret']:
                getattr(k8s, f"delete_namespaced_{self.type}")(self.name, self.namespace)


class ValidationProcedure(BaseModel, extra='forbid'):
    """
    Defines the procedure to evaluate whether a test is successful.
    """
    timeout_seconds:    float = Field(
                            default=60.,
                            description="Defines a timeout to declare a not successful test failed.",
                        ),
    clean_configs:      List[CleanConfig] = Field(
                            default=[],
                            description="List of operation defining the clean-up procedure.",
                        )
    check_pods:         List[CheckPod] = Field(
                            default=[],
                            description="List of checks on the pod status.",
                        )
    check_logs:         List[CheckLogs] = Field(
                            default=[],
                            description="List of checks on the logs of pods.",
                        )

    @staticmethod
    def from_dict(dictionary: Optional[Mapping[str, Any]] = None):
        """
        Parse a dictionary to produce a ValidationProcedure object.
        """
        if dictionary is None:
            return ValidationProcedure()
        
        return ValidationProcedure(**dictionary)

    def execute(self, timeout_multiplier: float = 1.):
        """
        Perform the tests.
        """
        start_time = datetime.now()
        succeeded = False
        try:
            timeout = timeout_multiplier * self.timeout_seconds
            while (datetime.now() - start_time).total_seconds() < timeout:
                try:
                    with kubernetes_api() as k8s:
                        for check_pod in self.check_pods:
                            check_pod.execute(k8s)
                        for check_logs in self.check_logs:
                            check_logs.execute(k8s)

                except RecoverableError:
                    time.sleep(1) 

                else:
                    succeeded = True
                    break
                
        finally:
            with kubernetes_api() as k8s:
                for cleanup in self.clean_configs:
                    cleanup.execute(k8s, succeeded=succeeded)

        if not succeeded: 
            raise TimeoutError(f"Validation failed after {self.timeout_seconds} seconds")


    

if __name__ == '__main__':
    import jsonschema2md

    json_schema = ValidationProcedure.model_json_schema()

    parser = jsonschema2md.Parser(
        examples_as_yaml=False,
        show_examples="all",
    )

    md_lines = parser.parse_schema(json_schema)
    print(''.join(md_lines))

