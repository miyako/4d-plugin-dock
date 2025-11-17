//%attributes = {"invisible":true,"preemptive":"incapable"}
#DECLARE()

//TRACE

$badge:=Num:C11(DOCK Get badge)
$badge+=1

DOCK SET BADGE(String:C10($badge))